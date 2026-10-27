require "set"

module Matter
  module Transport
    # Shared outgoing counter and incoming replay window. Secure peers are only
    # recorded after authentication; checking a counter never changes the window.
    class MessageCounter
      WINDOW_SIZE = 64

      enum CheckResult
        Accept
        Duplicate
        Stale
      end

      getter counter : UInt32
      getter max_received : UInt32?
      property maximum : UInt32 = UInt32::MAX
      @received_window = Set(UInt32).new
      @max_received : UInt32? = nil
      @restored_floor : UInt32? = nil
      @remaining_messages : UInt32? = nil

      def initialize(@counter : UInt32 = 0_u32, @rollover : Bool = true)
      end

      def next : UInt32
        remaining = @remaining_messages
        if remaining == 0_u32
          raise Matter::SessionError.new("Reserved message counter range is exhausted")
        end
        if @counter >= @maximum
          raise Matter::SessionError.new("Message counter overflow - session must be renegotiated") unless @rollover
          @counter = 0_u32
        else
          @counter += 1
        end
        @remaining_messages = remaining - 1_u32 if remaining
        @counter
      end

      def limit_messages(count : UInt32) : Nil
        @remaining_messages = count
      end

      def peek(message_id : UInt32) : CheckResult
        maximum = @max_received
        return CheckResult::Accept unless maximum
        return CheckResult::Stale if (floor = @restored_floor) && message_id <= floor
        return CheckResult::Accept if message_id > maximum
        return CheckResult::Duplicate if @received_window.includes?(message_id)
        return CheckResult::Stale if maximum - message_id > WINDOW_SIZE
        CheckResult::Accept
      end

      def check(message_id : UInt32) : CheckResult
        result = peek(message_id)
        return result unless result.accept?
        maximum = @max_received
        if maximum.nil? || message_id > maximum
          @max_received = message_id
          @received_window.reject! { |id| message_id - id > WINDOW_SIZE }
        end
        @received_window.add(message_id)
        result
      end

      def valid?(message_id : UInt32) : Bool
        check(message_id).accept?
      end

      def mark_received(message_id : UInt32) : Nil
        check(message_id)
      end

      def reset(value : UInt32 = 0_u32) : Nil
        @counter = value
        @remaining_messages = nil
        @received_window.clear
        @max_received = nil
        @restored_floor = nil
      end

      # Persistence stores the high watermark, so conservatively reject its
      # preceding window after restore instead of admitting previously seen ids.
      def restore_received(value : UInt32?) : Nil
        @received_window.clear
        @max_received = value
        @restored_floor = value
      end
    end
  end
end
