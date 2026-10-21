require "digest/sha256"

require "../storage/backend"
require "../storage/record"

module Matter
  module Controller
    # Controller-side ICD Check-In keys and replay state. An entry is bound to
    # the complete fabric identity; local fabric indices and UDP addresses are
    # deliberately absent because both may change after restart.
    class IcdPeerStore
      COLLECTION  = "controller_icd_peers"
      MAX_RECORDS = 64
      KEY_LENGTH  = 16

      struct Record
        include Storage::Record

        getter fabric_id : UInt64
        getter root_public_key : Bytes
        getter controller_node_id : UInt64
        getter device_node_id : UInt64
        getter key : Bytes
        getter counter_start : UInt32?
        getter last_counter : UInt32?
        getter pending_key : Bytes?
        getter pending_counter_start : UInt32?

        def initialize(@fabric_id : UInt64, @root_public_key : Bytes,
                       @controller_node_id : UInt64, @device_node_id : UInt64,
                       @key : Bytes, @counter_start : UInt32? = nil,
                       @last_counter : UInt32? = nil,
                       @pending_key : Bytes? = nil,
                       @pending_counter_start : UInt32? = nil)
        end

        def same_fabric?(fabric_id : UInt64, root_public_key : Bytes,
                         controller_node_id : UInt64) : Bool
          @fabric_id == fabric_id && @root_public_key == root_public_key &&
            @controller_node_id == controller_node_id
        end
      end

      def initialize(@backend : Storage::Backend)
        @backend.open unless @backend.open?
      end

      def find_peer(fabric_id : UInt64, root_public_key : Bytes,
                    controller_node_id : UInt64, device_node_id : UInt64) : Record?
        document = @backend.read(COLLECTION,
          record_id(fabric_id, root_public_key, controller_node_id, device_node_id))
        return unless document
        record = Record.from_document(document)
        return unless record.same_fabric?(fabric_id, root_public_key, controller_node_id) &&
                      record.device_node_id == device_node_id
        record
      end

      def records : Array(Record)
        @backend.all(COLLECTION).values.map { |document| Record.from_document(document) }
      end

      def save(record : Record) : Nil
        unless record.key.size == KEY_LENGTH &&
               (record.pending_key.nil? || record.pending_key.try(&.size) == KEY_LENGTH)
          raise Matter::ConfigurationError.new("ICD Check-In key must be 16 bytes")
        end
        id = record_id(record.fabric_id, record.root_public_key,
          record.controller_node_id, record.device_node_id)
        @backend.all(COLLECTION).each do |other_id, document|
          next if other_id == id
          other = Record.from_document(document)
          if other.key == record.key || other.pending_key == record.key ||
             (record.pending_key && (other.key == record.pending_key || other.pending_key == record.pending_key))
            raise Matter::ConfigurationError.new("ICD Check-In key is already assigned to another peer")
          end
        end
        if !@backend.read(COLLECTION, id) && @backend.ids(COLLECTION).size >= MAX_RECORDS
          raise Matter::ConfigurationError.new("ICD peer store is full")
        end
        @backend.write(COLLECTION, id, record.to_document)
      end

      def delete_peer(fabric_id : UInt64, root_public_key : Bytes,
                      controller_node_id : UInt64, device_node_id : UInt64) : Nil
        @backend.delete(COLLECTION,
          record_id(fabric_id, root_public_key, controller_node_id, device_node_id))
      end

      def remove_fabric(fabric_id : UInt64, root_public_key : Bytes,
                        controller_node_id : UInt64) : Nil
        @backend.transaction do
          @backend.all(COLLECTION).each do |id, document|
            entry = Record.from_document(document)
            @backend.delete(COLLECTION, id) if entry.same_fabric?(fabric_id,
                                                 root_public_key, controller_node_id)
          end
        end
      end

      private def record_id(fabric_id : UInt64, root_public_key : Bytes,
                            controller_node_id : UInt64, device_node_id : UInt64) : String
        identity = "#{fabric_id.to_s(16)}:#{root_public_key.hexstring}:" \
                   "#{controller_node_id.to_s(16)}:#{device_node_id.to_s(16)}"
        Digest::SHA256.hexdigest(identity)
      end
    end
  end
end
