require "set"

module Matter
  module Transport
    # Shared outgoing counter and incoming replay window. Secure peers are only
    # recorded after authentication; checking a counter never changes the window.
    class MessageCounter
      WINDOW_SIZE       = 64
      SERIAL_HALF_RANGE = 1_u32 << 31

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
      @refill : Proc(Tuple(UInt32, UInt32))? = nil
      @lease_validity : Proc(Nil)? = nil
      @lease_owner_token : UInt64? = nil
      @issued_messages : UInt64 = 0_u64
      @send_mutex = Mutex.new

      def initialize(@counter : UInt32 = 0_u32, @rollover : Bool = true)
      end

      def next : UInt32
        loop do
          assigned : UInt32? = nil
          refill : Proc(Tuple(UInt32, UInt32))? = nil
          @send_mutex.synchronize do
            @lease_validity.try(&.call)
            if @remaining_messages == 0_u32
              refill = @refill || raise Matter::SessionError.new("Reserved message counter range is exhausted")
            else
              if @counter >= @maximum
                raise Matter::SessionError.new("Message counter overflow - session must be renegotiated") unless @rollover
                @counter = 0_u32
              else
                @counter += 1
              end
              @remaining_messages = @remaining_messages.not_nil! - 1_u32 if @remaining_messages
              @issued_messages = @issued_messages &+ 1_u64
              assigned = @counter
            end
          end
          return value if value = assigned

          # Storage may hold its own transaction lock. Reserve outside the
          # send mutex so a transaction attempting to send cannot deadlock a
          # concurrent renewal. An overlapping renewal may leave a safe gap.
          start, count = refill.not_nil!.call
          raise Matter::SessionError.new("Counter lease returned an empty range") if count == 0_u32
          @send_mutex.synchronize do
            @lease_validity.try(&.call)
            if @remaining_messages == 0_u32 && (start == @counter || newer?(start, @counter))
              @counter = start
              @remaining_messages = count
            end
          end
        end
      end

      def limit_messages(count : UInt32) : Nil
        raise Matter::ConfigurationError.new("Cannot replace a leased counter range") if @lease_owner_token
        @remaining_messages = count
      end

      # Replenish a bounded send range before the next packet gets a counter.
      # The callback must commit its reservation before returning. Failure is
      # propagated and no counter is assigned.
      def refill_with(callback : Proc(Tuple(UInt32, UInt32))) : Nil
        raise Matter::ConfigurationError.new("Cannot replace a counter lease renewal") if @lease_owner_token
        @refill = callback
      end

      def bind_lease(owner : Object, start : UInt32, count : UInt32,
                     callback : Proc(Tuple(UInt32, UInt32))? = nil,
                     validity : Proc(Nil)? = nil) : Nil
        @send_mutex.synchronize do
          raise Matter::ConfigurationError.new("Message counter already has a lease owner") if @lease_owner_token
          raise Matter::ConfigurationError.new("Cannot bind a counter lease after a message was sent") unless @issued_messages == 0_u64
          @counter = start
          @remaining_messages = count
          @refill = callback
          @lease_validity = validity
          @lease_owner_token = owner.object_id.to_u64
        end
      end

      def leased_by?(owner : Object) : Bool
        @lease_owner_token == owner.object_id.to_u64
      end

      def peek(message_id : UInt32) : CheckResult
        maximum = @max_received
        return CheckResult::Accept unless maximum
        if floor = @restored_floor
          return CheckResult::Stale unless newer?(message_id, floor)
        end
        return CheckResult::Accept if newer?(message_id, maximum)
        return CheckResult::Duplicate if @received_window.includes?(message_id)
        backward = maximum &- message_id
        return CheckResult::Stale if backward >= SERIAL_HALF_RANGE || backward > WINDOW_SIZE
        CheckResult::Accept
      end

      def check(message_id : UInt32) : CheckResult
        result = peek(message_id)
        return result unless result.accept?
        maximum = @max_received
        if maximum.nil? || newer?(message_id, maximum)
          @max_received = message_id
          @received_window.reject! { |id| (message_id &- id) > WINDOW_SIZE }
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
        raise Matter::ConfigurationError.new("Cannot reset a leased message counter") if @lease_owner
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

      private def newer?(candidate : UInt32, reference : UInt32) : Bool
        return candidate > reference unless @rollover
        distance = candidate &- reference
        distance > 0_u32 && distance < SERIAL_HALF_RANGE
      end
    end
  end
end
