require "log"
require "../../storage/backend"
require "../../storage/record"
require "./case"

module Matter
  module Session
    module Case
      # Persists only the secret and authenticated identity needed to resume
      # CASE. A record is bound to the full fabric identity, not its reusable
      # local fabric index or a network address.
      class ResumptionStore
        Log         = ::Log.for("matter.session.case.resumption_store")
        COLLECTION  = Storage::Collections::CASE_RESUMPTIONS
        MAX_RECORDS = 64
        MAX_AGE     = 7.days

        struct Record
          include Storage::Record

          getter fabric_id : UInt64
          getter root_public_key : Bytes
          getter local_node_id : UInt64
          getter peer_node_id : UInt64
          getter resumption_id : Bytes
          getter shared_secret : Bytes
          getter peer_subject_ids : Array(UInt64)
          getter peer_icac : Bytes?
          getter created_at : Time
          # Nil identifies a record saved before CASE direction was persisted.
          # Such a record is never eligible for a role-specific resume lookup.
          getter role : Role?

          def initialize(@fabric_id : UInt64, @root_public_key : Bytes,
                         @local_node_id : UInt64, @peer_node_id : UInt64,
                         @resumption_id : Bytes, @shared_secret : Bytes,
                         @peer_subject_ids : Array(UInt64), @peer_icac : Bytes? = nil,
                         @created_at : Time = Time.utc, @role : Role? = nil)
          end

          def expired?(now : Time = Time.utc) : Bool
            @created_at + MAX_AGE < now
          end

          def same_peer?(other : Record) : Bool
            @fabric_id == other.fabric_id && @root_public_key == other.root_public_key &&
              @local_node_id == other.local_node_id && @peer_node_id == other.peer_node_id &&
              @role == other.role
          end

          def same_peer_identity?(other : Record) : Bool
            @fabric_id == other.fabric_id && @root_public_key == other.root_public_key &&
              @local_node_id == other.local_node_id && @peer_node_id == other.peer_node_id
          end
        end

        def initialize(@backend : Storage::Backend)
          @backend.open unless @backend.open?
        end

        def find_by_id(id : Bytes, role : Role? = nil) : Record?
          return unless id.size == RESUMPTION_ID_LENGTH
          document = @backend.read(COLLECTION, id.hexstring)
          return unless document
          record = Record.from_document(document)
          return if role && record.role != role
          if record.expired?
            @backend.delete(COLLECTION, id.hexstring)
            return
          end
          record
        end

        def find_by_peer(fabric_id : UInt64, root_public_key : Bytes,
                         local_node_id : UInt64, peer_node_id : UInt64,
                         role : Role? = nil) : Record?
          @backend.all(COLLECTION).each do |id, document|
            record = Record.from_document(document)
            if record.expired?
              @backend.delete(COLLECTION, id)
              next
            end
            if record.fabric_id == fabric_id && record.root_public_key == root_public_key &&
               record.local_node_id == local_node_id && record.peer_node_id == peer_node_id &&
               (role.nil? || record.role == role)
              return record
            end
          end
          nil
        end

        def save(record : Record) : Nil
          unless record.resumption_id.size == RESUMPTION_ID_LENGTH && record.shared_secret.size == 32
            raise Matter::ConfigurationError.new("CASE resumption ID or shared secret has an invalid length")
          end
          @backend.transaction do
            @backend.all(COLLECTION).each do |id, document|
              old = Record.from_document(document)
              if old.same_peer?(record) ||
                 (old.role.nil? && old.same_peer_identity?(record)) || old.expired?
                @backend.delete(COLLECTION, id)
              end
            end
            if @backend.read(COLLECTION, record.resumption_id.hexstring)
              raise Matter::ConfigurationError.new("CASE resumption ID already belongs to another peer")
            end
            if @backend.ids(COLLECTION).size >= MAX_RECORDS
              oldest = @backend.all(COLLECTION).min_by { |_, document| Record.from_document(document).created_at }
              @backend.delete(COLLECTION, oldest[0])
            end
            @backend.write(COLLECTION, record.resumption_id.hexstring, record.to_document)
          end
        end

        def remove_fabric(fabric_id : UInt64, root_public_key : Bytes,
                          local_node_id : UInt64, role : Role? = nil,
                          include_legacy : Bool = false) : Nil
          @backend.transaction do
            @backend.all(COLLECTION).each do |id, document|
              record = decode_record(document, id)
              next unless record
              if record.fabric_id == fabric_id && record.root_public_key == root_public_key &&
                 record.local_node_id == local_node_id &&
                 (role.nil? || record.role == role || (include_legacy && record.role.nil?))
                @backend.delete(COLLECTION, id)
              end
            end
          end
        end

        private def decode_record(document : Storage::Document, id : String) : Record?
          Record.from_document(document)
        rescue ex
          Log.warn(exception: ex) { "Keeping undecodable CASE resumption #{id} during fabric removal" }
          nil
        end
      end
    end
  end
end
