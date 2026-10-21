require "./btp_codec"

module Matter
  module Transport
    # GATT-independent BTP v4 sequencing and message segmentation (§4.19.4).
    # A BLE adapter writes returned frames in order, passes received frames to
    # #receive_packet, and calls #send_ack on its ACK timer or when #ack_urgent?.
    class BtpSession
      MIN_FRAGMENT_SIZE         =   20
      MAX_FRAGMENT_SIZE         =  244
      MAX_WINDOW_SIZE           =  255
      MAX_MATTER_MESSAGE_SIZE   = 1280
      IMMEDIATE_ACK_FREE_SLOTS  =    2
      RESERVED_ACK_WINDOW_SLOTS =    1
      SEQUENCE_MODULUS          =  256
      DATA_HEADER_SIZE          =    2
      BEGIN_LENGTH_SIZE         =    2
      ACK_FIELD_SIZE            =    1
      ACK_RECEIVE_TIMEOUT       = 15.seconds
      ACK_SEND_TIMEOUT          = 5.seconds
      CENTRAL_IDLE_TIMEOUT      = 60.seconds

      enum Role : UInt8
        Central
        Peripheral
      end

      getter role : Role
      getter fragment_size : Int32
      getter window_size : Int32

      @next_outgoing_sequence : UInt8
      @last_incoming_sequence : UInt8
      @last_ack_sent : UInt8
      @last_ack_received : UInt8
      @sent_unacked : Array(UInt8)
      @outgoing_messages : Array(Bytes)
      @outgoing_offset : Int32
      @incoming_payload : Bytes?
      @incoming_expected_length : Int32?
      @closed : Bool
      @ack_receive_deadline : Time::Instant?
      @ack_send_deadline : Time::Instant?
      @idle_deadline : Time::Instant?

      def initialize(@role : Role, @fragment_size : Int32, @window_size : Int32,
                     now : Time::Instant = Time.instant)
        unless @fragment_size.in?(MIN_FRAGMENT_SIZE..MAX_FRAGMENT_SIZE) && @window_size.in?(1..MAX_WINDOW_SIZE)
          raise Matter::ConfigurationError.new("Invalid BTP fragment or window size")
        end
        @next_outgoing_sequence = role.central? ? 0_u8 : 1_u8
        @last_incoming_sequence = role.central? ? 0_u8 : UInt8::MAX
        @last_ack_sent = UInt8::MAX
        @last_ack_received = UInt8::MAX
        # The peripheral's handshake response occupies outgoing sequence 0
        # until the central acknowledges it. The central owes ACK 0.
        @sent_unacked = role.central? ? [] of UInt8 : [0_u8]
        @outgoing_messages = [] of Bytes
        @outgoing_offset = 0
        @incoming_payload = nil
        @incoming_expected_length = nil
        @closed = false
        @ack_receive_deadline = role.peripheral? ? now + ACK_RECEIVE_TIMEOUT : nil
        @ack_send_deadline = role.central? ? now + ACK_SEND_TIMEOUT : nil
        @idle_deadline = nil
      end

      def closed? : Bool
        @closed
      end

      def close : Nil
        @closed = true
        @outgoing_messages.clear
        @incoming_payload = nil
        @incoming_expected_length = nil
        @ack_receive_deadline = nil
        @ack_send_deadline = nil
        @idle_deadline = nil
      end

      def queue_message(data : Bytes) : Nil
        ensure_open
        unless data.size.in?(1..MAX_MATTER_MESSAGE_SIZE)
          raise Matter::ProtocolError.new("BTP Matter message length is out of range")
        end
        @outgoing_messages << data.dup
      end

      # Return every queued data frame that fits the peer's current receive
      # window. The caller writes them in order before processing more input.
      def drain_outgoing(now : Time::Instant = Time.instant) : Array(Bytes)
        ensure_open
        frames = [] of Bytes
        while message = @outgoing_messages.first?
          carries_ack = pending_ack?
          free = remote_window_free_slots
          break if free == 0 || (free <= RESERVED_ACK_WINDOW_SLOTS && !carries_ack)

          beginning = @outgoing_offset == 0
          header_size = DATA_HEADER_SIZE + (beginning ? BEGIN_LENGTH_SIZE : 0) +
                        (carries_ack ? ACK_FIELD_SIZE : 0)
          remaining = message.size - @outgoing_offset
          segment_length = {remaining, @fragment_size - header_size}.min
          ending = segment_length == remaining
          flags = beginning ? BtpCodec::Flags::Begin : BtpCodec::Flags::Continue
          flags |= BtpCodec::Flags::End if ending
          flags |= BtpCodec::Flags::Ack if carries_ack
          ack_number = carries_ack ? @last_incoming_sequence : nil
          length = beginning ? message.size.to_u16 : nil
          payload = message[@outgoing_offset, segment_length].dup
          frames << BtpCodec.encode_packet(BtpCodec::Packet.new(flags,
            take_sequence_number(now), ack_number, length, payload))
          if carries_ack
            @last_ack_sent = @last_incoming_sequence
            @ack_send_deadline = nil
          end
          @idle_deadline = now + CENTRAL_IDLE_TIMEOUT if @role.central?
          @outgoing_offset += segment_length
          if ending
            @outgoing_messages.shift
            @outgoing_offset = 0
          end
        end
        frames
      end

      # A standalone ACK also consumes one peer window slot. Nil means there
      # is no new sequence to acknowledge or the peer window is full.
      def send_ack(now : Time::Instant = Time.instant) : Bytes?
        ensure_open
        return unless pending_ack? && remote_window_free_slots > 0
        sequence = take_sequence_number(now)
        frame = BtpCodec.encode_packet(BtpCodec::Packet.new(BtpCodec::Flags::Ack,
          sequence, @last_incoming_sequence, nil, Bytes.empty))
        @last_ack_sent = @last_incoming_sequence
        @ack_send_deadline = nil
        frame
      end

      def pending_ack? : Bool
        @last_incoming_sequence != @last_ack_sent
      end

      def ack_urgent? : Bool
        pending_ack? && local_window_free_slots <= IMMEDIATE_ACK_FREE_SLOTS
      end

      # Returns a complete Matter message only on its ending segment. Every
      # received packet (including ACK-only) must have the next sequence number.
      def receive_packet(frame : Bytes, now : Time::Instant = Time.instant) : Bytes?
        ensure_open
        begin
          if frame.size > @fragment_size
            raise Matter::ProtocolError.new("BTP packet exceeds negotiated fragment size")
          end
          packet = BtpCodec.decode_packet(frame)
          expected_sequence = @last_incoming_sequence &+ 1_u8
          unless packet.sequence_number == expected_sequence
            raise Matter::ProtocolError.new("BTP packet sequence is out of order")
          end
          if local_window_free_slots == 0
            raise Matter::ProtocolError.new("BTP receive window is full")
          end
          if ack_number = packet.ack_number
            accept_ack(ack_number, now)
          end
          completed = accept_segment(packet)
          @last_incoming_sequence = packet.sequence_number
          @ack_send_deadline ||= now + ACK_SEND_TIMEOUT
          completed
        rescue ex : Matter::Error
          close
          raise ex
        end
      end

      # The GATT adapter polls this at the next deadline. A timed-out session
      # closes; an ACK that cannot fit the peer window remains pending.
      def poll(now : Time::Instant = Time.instant) : Bytes?
        ensure_open
        if deadline = @ack_receive_deadline
          if now >= deadline
            close
            raise Matter::TimeoutError.new("BTP ACK receive timeout")
          end
        end
        if deadline = @idle_deadline
          if now >= deadline
            close
            raise Matter::TimeoutError.new("BTP central idle timeout")
          end
        end
        if deadline = @ack_send_deadline
          return send_ack(now) if now >= deadline
        end
        nil
      end

      private def accept_ack(number : UInt8, now : Time::Instant) : Nil
        return if number == @last_ack_received
        index = @sent_unacked.index(number)
        unless index
          raise Matter::ProtocolError.new("BTP ACK refers to an unsent sequence")
        end
        @sent_unacked.shift(index + 1)
        @last_ack_received = number
        @ack_receive_deadline = @sent_unacked.empty? ? nil : now + ACK_RECEIVE_TIMEOUT
      end

      private def accept_segment(packet : BtpCodec::Packet) : Bytes?
        flags = packet.flags
        if flags.includes?(BtpCodec::Flags::Begin)
          if @incoming_payload
            raise Matter::ProtocolError.new("BTP beginning arrived before previous message ended")
          end
          length = packet.message_length || raise Matter::ProtocolError.new("BTP beginning has no length")
          if length > MAX_MATTER_MESSAGE_SIZE
            raise Matter::ProtocolError.new("BTP message exceeds maximum Matter size")
          end
          @incoming_expected_length = length.to_i
          @incoming_payload = packet.payload.dup
        elsif flags.includes?(BtpCodec::Flags::Continue)
          previous = @incoming_payload || raise Matter::ProtocolError.new("BTP continuation has no beginning")
          joined = Bytes.new(previous.size + packet.payload.size)
          joined[0, previous.size].copy_from(previous)
          joined[previous.size, packet.payload.size].copy_from(packet.payload)
          @incoming_payload = joined
        end

        if payload = @incoming_payload
          expected = @incoming_expected_length || raise Matter::ProtocolError.new("BTP message length missing")
          if payload.size > expected
            raise Matter::ProtocolError.new("BTP segments exceed declared message length")
          end
          if flags.includes?(BtpCodec::Flags::End)
            unless payload.size == expected
              raise Matter::ProtocolError.new("BTP ending segment does not complete message")
            end
            @incoming_payload = nil
            @incoming_expected_length = nil
            return payload
          end
        end
        nil
      end

      private def take_sequence_number(now : Time::Instant) : UInt8
        sequence = @next_outgoing_sequence
        @next_outgoing_sequence &+= 1_u8
        @sent_unacked << sequence
        @ack_receive_deadline ||= now + ACK_RECEIVE_TIMEOUT
        sequence
      end

      private def remote_window_free_slots : Int32
        @window_size - @sent_unacked.size
      end

      private def local_window_free_slots : Int32
        distance = (@last_incoming_sequence.to_i - @last_ack_sent.to_i) % SEQUENCE_MODULUS
        @window_size - distance
      end

      private def ensure_open : Nil
        raise Matter::ProtocolError.new("BTP session is closed") if @closed
      end
    end
  end
end
