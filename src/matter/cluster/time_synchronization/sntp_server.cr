require "socket"

module Matter
  module Cluster
    class TimeSynchronization
      # Small SNTPv4 UDP responder for the opt-in NTPS feature. It serves only
      # UTC already accepted by the cluster and never adjusts the host clock.
      class SntpServer
        Log = ::Log.for("matter.cluster.time_synchronization.sntp_server")

        PACKET_SIZE           =      48
        NTP_PORT              =     123
        REQUEST_MODE          =    3_u8
        RESPONSE_HEADER       = 0x24_u8
        VERSION_MASK          = 0x38_u8
        VERSION_4             = 0x20_u8
        MODE_MASK             = 0x07_u8
        STRATUM               =    2_u8
        SECONDS_PRECISION     =    0_u8
        MILLIS_PRECISION      = 0xF6_u8
        MICROS_PRECISION      = 0xEC_u8
        RECEIVE_TIMEOUT       = 200.milliseconds
        NTP_TO_MATTER_SECONDS = 3_155_673_600_u64
        MICROS_PER_SECOND     =     1_000_000_u64
        FRACTION_SCALE        = 4_294_967_296_u64

        @socket : UDPSocket?
        @done : ::Channel(Nil)?
        @running : Bool = false
        @bound_port : Int32

        def initialize(@cluster : TimeSynchronization, @address : String = "::",
                       @requested_port : Int32 = NTP_PORT)
          @bound_port = @requested_port
        end

        def port : Int32
          @bound_port
        end

        def start : Nil
          return if @running
          raise ConfigurationError.new("SNTP server requires the NTPServer feature") unless @cluster.feature_map.ntp_server?
          socket = UDPSocket.new(Socket::Family::INET6)
          begin
            socket.bind(@address, @requested_port)
            socket.read_timeout = RECEIVE_TIMEOUT
            @bound_port = socket.local_address.port
            @socket = socket
            @running = true
            done = ::Channel(Nil).new
            @done = done
            spawn { receive_loop(socket, done) }
            @cluster.report_ntp_server_bound(true)
          rescue error
            socket.close
            raise error
          end
        end

        def stop : Nil
          socket = @socket
          return unless socket
          @running = false
          @cluster.report_ntp_server_bound(false)
          socket.close
          @done.try(&.receive?)
          @socket = nil
          @done = nil
        end

        def self.respond(request : Bytes, utc_time : UInt64?, granularity : Granularity = Granularity::Seconds) : Bytes?
          utc = utc_time
          return unless utc && representable_utc?(utc) && request.size == PACKET_SIZE
          return unless request[0] & MODE_MASK == REQUEST_MODE
          version = request[0] & VERSION_MASK
          return unless version == VERSION_4
          return if granularity.value < Granularity::Seconds.value

          seconds = NTP_TO_MATTER_SECONDS + utc // MICROS_PER_SECOND
          fraction = utc % MICROS_PER_SECOND * FRACTION_SCALE // MICROS_PER_SECOND

          timestamp = Bytes.new(8)
          4.times do |index|
            shift = (3 - index) * 8
            timestamp[index] = ((seconds >> shift) & 0xFF).to_u8
            timestamp[4 + index] = ((fraction >> shift) & 0xFF).to_u8
          end

          response = Bytes.new(PACKET_SIZE, 0_u8)
          response[0] = RESPONSE_HEADER
          response[1] = STRATUM
          response[2] = request[2]
          response[3] = case granularity
                        when Granularity::Microseconds then MICROS_PRECISION
                        when Granularity::Milliseconds then MILLIS_PRECISION
                        else                                SECONDS_PRECISION
                        end
          response[12, 4].copy_from(Bytes[0x4D, 0x41, 0x54, 0x00]) # MAT reference ID
          response[16, 8].copy_from(timestamp)
          response[24, 8].copy_from(request[40, 8])
          response[32, 8].copy_from(timestamp)
          response[40, 8].copy_from(timestamp)
          response
        end

        def self.representable_utc?(utc_time : UInt64?) : Bool
          !!utc_time && utc_time.as(UInt64) // MICROS_PER_SECOND <= UInt32::MAX.to_u64 - NTP_TO_MATTER_SECONDS
        end

        private def receive_loop(socket : UDPSocket, done : ::Channel(Nil)) : Nil
          buffer = Bytes.new(512)
          while @running
            begin
              size, sender = socket.receive(buffer)
              if @cluster.ntp_server_available? && (response = self.class.respond(buffer[0, size], @cluster.utc_time, @cluster.granularity))
                socket.send(response, sender)
              end
            rescue IO::TimeoutError
              next
            rescue error : IO::Error | Socket::Error
              Log.warn(exception: error) { "SNTP receive loop stopped" } if @running
              break
            end
          end
        ensure
          @running = false
          @cluster.report_ntp_server_bound(false)
          done.close
        end
      end
    end
  end
end
