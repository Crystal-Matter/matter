require "../error"
require "../fabric"
require "../storage/backend"

module Matter
  module Commissioning
    # Durable undo record for the one NOC mutation allowed under a fail-safe.
    # The record is flushed before the fabric document can change. Recovery
    # runs before FabricTable or CASE state is loaded by a device.
    module CredentialJournal
      COLLECTION = Storage::Collections::DEVICE
      ID         = "pending_operational_credentials"
      OPERATION  = "operation"
      INDEX      = "fabric_index"
      PREVIOUS   = "previous_fabric"
      ADD        = "add"
      UPDATE     = "update"

      def self.begin_add(backend : Storage::Backend, index : UInt8) : Nil
        write(backend, Storage::Document{OPERATION => ADD, INDEX => index.to_i64})
      end

      def self.begin_update(backend : Storage::Backend, fabric : Fabric) : Nil
        write(backend, Storage::Document{
          OPERATION => UPDATE,
          INDEX     => fabric.fabric_index.to_i64,
          PREVIOUS  => fabric.to_document,
        })
      end

      def self.clear(backend : Storage::Backend) : Nil
        backend.transaction { backend.delete(COLLECTION, ID) }
      end

      # Returns the removed AddNOC index; its fabric-scoped ACL still needs
      # removal from the restored AccessControl cluster before clearing the
      # record. UpdateNOC has no fabric-scoped cluster data to remove.
      def self.recover(backend : Storage::Backend) : UInt8?
        document = backend.read(COLLECTION, ID)
        return unless document

        index = parse_index(document)
        case document[OPERATION]?
        when ADD
          backend.transaction { backend.delete(Storage::Collections::FABRICS, index.to_s) }
          index
        when UPDATE
          previous = document[PREVIOUS]?.as?(Storage::Document) ||
                     raise StorageError.new("Invalid pending UpdateNOC journal: missing fabric snapshot")
          fabric = Fabric.from_document(previous)
          unless fabric.fabric_index == index
            raise StorageError.new("Invalid pending UpdateNOC journal: fabric index mismatch")
          end
          backend.transaction do
            backend.write(Storage::Collections::FABRICS, index.to_s, previous)
            backend.delete(COLLECTION, ID)
          end
          nil
        else
          raise StorageError.new("Invalid pending credential journal operation")
        end
      rescue ex : StorageError
        raise ex
      rescue ex
        raise StorageError.new("Cannot recover pending operational credentials: #{ex.message}")
      end

      private def self.write(backend : Storage::Backend, document : Storage::Document) : Nil
        if backend.read(COLLECTION, ID)
          raise StorageError.new("An operational credential transaction is already pending")
        end
        backend.transaction { backend.write(COLLECTION, ID, document) }
      end

      private def self.parse_index(document : Storage::Document) : UInt8
        value = document[INDEX]?
        number = case value
                 when Int64, UInt64 then value
                 else                    raise StorageError.new("Invalid pending credential journal fabric index")
                 end
        unless Fabric::MIN_FABRIC_INDEX <= number <= Fabric::MAX_FABRIC_INDEX
          raise StorageError.new("Invalid pending credential journal fabric index")
        end
        number.to_u8
      end
    end
  end
end
