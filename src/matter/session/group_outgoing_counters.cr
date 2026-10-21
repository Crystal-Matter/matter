require "../storage/backend"

module Matter
  module Session
    # Node-global group data/control counters. Each reservation is durably
    # written before a counter from that block is returned. On restart the
    # unused tail is skipped, so a source/key never repeats an AES-CCM nonce.
    class GroupOutgoingCounters
      COLLECTION  = Storage::Collections::DEVICE
      RECORD_ID   = "group-outgoing-counters"
      DATA_KEY    = "data"
      CONTROL_KEY = "control"

      RESERVATION_SIZE =        1000_u32
      RANDOM_MASK      = 0x0FFF_FFFF_u32

      @mutex = Mutex.new
      @data_counter : UInt32
      @control_counter : UInt32
      @data_high : UInt32
      @control_high : UInt32

      def initialize(@backend : Storage::Backend)
        raise Matter::SessionError.new("Group counters require durable storage") if @backend.path.nil?
        raise Matter::StorageError.new("Group counter storage is closed") unless @backend.open?
        if document = @backend.read(COLLECTION, RECORD_ID)
          @data_counter = read_counter(document, DATA_KEY)
          @control_counter = read_counter(document, CONTROL_KEY)
        else
          @data_counter = random_initial_counter
          @control_counter = random_initial_counter
        end
        @data_high = reserve_limit(@data_counter)
        @control_high = reserve_limit(@control_counter)
        persist
      end

      def next_data : UInt32
        next_counter(false)
      end

      def next_control : UInt32
        next_counter(true)
      end

      private def next_counter(control : Bool) : UInt32
        @mutex.synchronize do
          if control
            if @control_counter >= @control_high - 1
              new_high = reserve_limit(@control_high)
              persist(@data_high, new_high)
              @control_high = new_high
            end
            @control_counter += 1
          else
            if @data_counter >= @data_high - 1
              new_high = reserve_limit(@data_high)
              persist(new_high, @control_high)
              @data_high = new_high
            end
            @data_counter += 1
          end
        end
      end

      private def random_initial_counter : UInt32
        (IO::ByteFormat::LittleEndian.decode(UInt32, Random::Secure.random_bytes(4)) & RANDOM_MASK) + 1_u32
      end

      private def reserve_limit(counter : UInt32) : UInt32
        if counter > UInt32::MAX - RESERVATION_SIZE
          raise Matter::SessionError.new("Group message counter exhausted; rotate the epoch key")
        end
        counter + RESERVATION_SIZE
      end

      private def read_counter(document : Storage::Document, key : String) : UInt32
        value = document[key]?
        unless value.is_a?(Int64 | UInt64) && value >= 1 && value <= UInt32::MAX
          raise Matter::StorageError.new("Invalid persisted group #{key} counter")
        end
        value.to_u32
      end

      private def persist(data_high : UInt32 = @data_high, control_high : UInt32 = @control_high) : Nil
        @backend.write(COLLECTION, RECORD_ID,
          Storage::Document{DATA_KEY => data_high.to_i64, CONTROL_KEY => control_high.to_i64})
      end
    end
  end
end
