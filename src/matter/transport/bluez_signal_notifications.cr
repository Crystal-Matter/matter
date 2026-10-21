require "./bluez_central"

module Matter
  module Transport
    module Bluez
      # A GATT C2 notification source. The signal subscription must become
      # active before StartNotify, since that call can trigger a BTP response.
      module SignalSource
        abstract def subscribe_values(path : String, &callback : Bytes -> Nil) : UInt32
        abstract def start_notify(path : String) : Nil
        abstract def stop_notify(path : String) : Nil
        abstract def unsubscribe_values(subscription_id : UInt32) : Nil
        abstract def dispatch_pending : Nil
      end

      # Adapts BlueZ PropertiesChanged(Value) signals to complete BTP fragments.
      class SignalNotifications < Notifications
        MAX_QUEUED_FRAMES = 128
        POLL_INTERVAL     = 1.millisecond

        @frames = [] of Bytes
        @mutex = Mutex.new
        @subscription_id : UInt32
        @closed = false
        @overflowed = false

        def self.open(source : SignalSource, path : String) : self
          new(source, path)
        end

        private def initialize(@source : SignalSource, @path : String)
          @subscription_id = @source.subscribe_values(@path) { |frame| enqueue(frame) }
          begin
            @source.start_notify(@path)
          rescue ex
            @source.unsubscribe_values(@subscription_id)
            raise ex
          end
        end

        def mtu : Int32?
          nil
        end

        def read(timeout_span : Time::Span) : Bytes?
          deadline = Time.instant + timeout_span
          loop do
            frame, closed, overflowed = @mutex.synchronize { {@frames.shift?, @closed, @overflowed} }
            raise Matter::TransportError.new("BlueZ C2 indication queue overflowed") if overflowed
            return frame if frame
            return if closed || Time.instant >= deadline
            @source.dispatch_pending
            sleep(POLL_INTERVAL)
          end
        end

        def close : Nil
          first_close = @mutex.synchronize do
            next false if @closed
            @closed = true
            true
          end
          return unless first_close
          begin
            @source.stop_notify(@path)
          ensure
            @source.unsubscribe_values(@subscription_id)
          end
        end

        private def enqueue(frame : Bytes) : Nil
          @mutex.synchronize do
            return if @closed || @overflowed
            if @frames.size >= MAX_QUEUED_FRAMES
              @overflowed = true
            else
              @frames << frame.dup
            end
          end
        end
      end
    end
  end
end
