require "./fabric"
require "./debouncer"
require "./storage/backend"
require "log"

module Matter
  # FabricTable manages the collection of fabrics on a device
  #
  # Matter devices can be members of multiple fabrics simultaneously (multi-admin).
  # Each fabric represents a separate administrative domain with its own trust root,
  # operational certificates, and access control.
  #
  # The FabricTable:
  # - Stores up to a device-specific maximum number of fabrics (typically 16)
  # - Assigns unique local fabric indices (1-254)
  # - Persists fabrics to storage
  # - Provides lookup by fabric_index or fabric_id
  # - Handles fabric lifecycle (add, update, remove)
  #
  # Specification: Matter 1.4 § 4.13.3 (Fabric Table)
  class FabricTable
    Log = ::Log.for("matter.fabric_table")

    enum FabricMutation
      Add
      Update
      Remove
      Quarantine
    end

    # Every fabric is one document in this collection, keyed by fabric index.
    COLLECTION = Storage::Collections::FABRICS

    # Maximum number of fabrics a device can support
    # Matter spec requires minimum 5, but devices may support more
    DEFAULT_MAX_FABRICS = 16_u8
    MIN_MAX_FABRICS     =  5_u8
    MAX_MAX_FABRICS     = Fabric::MAX_FABRIC_INDEX

    # Fabrics indexed by fabric_index (1-254)
    @fabrics : Hash(UInt8, Fabric)
    # Copy the identity when a fabric enters the table. Fabric objects and
    # their public-key bytes are mutable, so comparing two Fabric references
    # cannot detect an in-place identity change.
    @identities : Hash(UInt8, String) = Hash(UInt8, String).new
    @removal_guards : Array(Proc(Fabric, Nil)) = [] of Proc(Fabric, Nil)
    @quarantined : Set(UInt8) = Set(UInt8).new

    # Storage backend for persistence
    @backend : Storage::Backend

    getter backend : Storage::Backend

    property on_fabric_removed : Proc(Fabric, Nil)?

    # Called before any public fabric-table mutation, including persistence.
    property on_before_fabric_change : Proc(FabricMutation, UInt8, Nil)?
    property on_before_clear : Proc(Nil)?

    # The device's reentrant protocol mutex, installed before transport starts.
    property protocol_lock : Mutex? = nil

    # Security cleanup registered by the device runtime and SecureChannel.
    # Host observers may replace `on_fabric_removed` without replacing guards.
    def register_removal_guard(&block : Fabric -> Nil) : Nil
      @removal_guards << block
    end

    # Fabrics whose `last_used_at` changed and have not been written yet.
    @dirty : Hash(UInt8, Fabric) = Hash(UInt8, Fabric).new

    # Maximum number of fabrics this device supports
    property max_fabrics : UInt8

    # When set, `mark_fabric_used` defers its write to this debouncer; the
    # owner calls `flush_pending_writes` from the debounced action. Without a
    # debouncer every change is written immediately.
    property write_debouncer : Debouncer?

    def initialize(
      @backend : Storage::Backend,
      @max_fabrics : UInt8 = DEFAULT_MAX_FABRICS,
    )
      @fabrics = Hash(UInt8, Fabric).new

      raise ArgumentError.new("max_fabrics must be >= #{MIN_MAX_FABRICS} (Matter requirement)") if @max_fabrics < MIN_MAX_FABRICS
      raise ArgumentError.new("max_fabrics must be <= #{MAX_MAX_FABRICS}") if @max_fabrics > MAX_MAX_FABRICS

      load_from_storage
    end

    # Add a new fabric to the table
    def add_fabric(fabric : Fabric) : Bool
      protocol_lock = @protocol_lock
      protocol_lock.try(&.lock)
      @on_before_fabric_change.try(&.call(FabricMutation::Add, fabric.fabric_index))
      # Check if we're at capacity
      if @fabrics.size >= @max_fabrics
        return false
      end

      # Check if fabric_index is already in use
      if @fabrics.has_key?(fabric.fabric_index) || quarantined?(fabric.fabric_index)
        return false
      end

      # Check for duplicate fabric identity (root_public_key + fabric_id).
      # Note: Fabric IDs are not globally unique across fabrics; the unique key is
      # (RootPublicKey, FabricId) per Matter spec.
      if find_by_fabric_identity(fabric.fabric_id, fabric.root_public_key)
        return false
      end

      persist_fabric(fabric)
      @fabrics[fabric.fabric_index] = fabric
      @identities[fabric.fabric_index] = fabric.storage_identity
      true
    ensure
      protocol_lock.try(&.unlock)
    end

    # Add a fabric with automatic index assignment
    def add_fabric_auto_index(
      fabric_id : UInt64,
      node_id : UInt64,
      root_public_key : Bytes,
      operational_cert : Bytes,
      operational_key : Crypto::Key,
      ipk : Bytes,
      vendor_id : UInt16 = Fabric::DEFAULT_VENDOR_ID,
      label : String = "",
      intermediate_cert : Bytes? = nil,
      root_cert : Bytes? = nil,
      fabric_index : UInt8? = nil,
    ) : Fabric?
      protocol_lock = @protocol_lock
      protocol_lock.try(&.lock)
      # Find next available fabric index
      fabric_index ||= next_available_index
      return unless fabric_index

      # Create fabric
      fabric = Fabric.new(
        fabric_id: fabric_id,
        fabric_index: fabric_index,
        node_id: node_id,
        root_public_key: root_public_key,
        operational_cert: operational_cert,
        operational_key: operational_key,
        ipk: ipk,
        vendor_id: vendor_id,
        label: label,
        intermediate_cert: intermediate_cert,
        root_cert: root_cert,
        cats: Crypto::MatterCertificate.subject_ids_from_tlv(operational_cert).compact_map do |subject_id|
          node_id = DataType::NodeId.new(subject_id)
          node_id.extract_as_case_authenticated_tag if node_id.case_authenticated_tag?
        end
      )

      # Add fabric
      add_fabric(fabric) ? fabric : nil
    ensure
      protocol_lock.try(&.unlock)
    end

    # Update an existing fabric
    def update_fabric(fabric : Fabric) : Bool
      protocol_lock = @protocol_lock
      protocol_lock.try(&.lock)
      @on_before_fabric_change.try(&.call(FabricMutation::Update, fabric.fabric_index))
      # Fabric must already exist
      return false unless @fabrics.has_key?(fabric.fabric_index)
      return false if quarantined?(fabric.fabric_index)
      return false unless @identities[fabric.fabric_index]? == fabric.storage_identity

      persist_fabric(fabric)
      @fabrics[fabric.fabric_index] = fabric
      true
    ensure
      protocol_lock.try(&.unlock)
    end

    # Remove a fabric by fabric_index
    def remove_fabric(fabric_index : UInt8) : Bool
      protocol_lock = @protocol_lock
      protocol_lock.try(&.lock)
      @on_before_fabric_change.try(&.call(FabricMutation::Remove, fabric_index))
      fabric = @fabrics[fabric_index]?
      return false unless fabric
      return false if identity_changed?(fabric_index)

      @removal_guards.each(&.call(fabric))
      @on_fabric_removed.try(&.call(fabric))
      # Keep the index reserved if durable deletion fails. A later AddNOC must
      # not assign it to a different fabric while the old document remains.
      @backend.delete(COLLECTION, fabric_index.to_s)
      @fabrics.delete(fabric_index)
      @identities.delete(fabric_index)
      @dirty.delete(fabric_index)
      true
    ensure
      protocol_lock.try(&.unlock)
    end

    # Remove a fabric by fabric_id
    def remove_fabric_by_id(fabric_id : UInt64) : Bool
      protocol_lock = @protocol_lock
      protocol_lock.try(&.lock)
      fabric = find_by_fabric_id(fabric_id)
      return false unless fabric

      remove_fabric(fabric.fabric_index)
    ensure
      protocol_lock.try(&.unlock)
    end

    # Get a fabric by fabric_index
    def get_fabric(fabric_index : UInt8) : Fabric?
      return if identity_changed?(fabric_index)
      @fabrics[fabric_index]?
    end

    # An ambiguous storage failure leaves the durable deletion outcome
    # unknown. Keep the index reserved and reject its operational traffic
    # until the backend is reopened and its undo journal is resolved.
    def quarantine(fabric_index : UInt8) : Nil
      protocol_lock = @protocol_lock
      protocol_lock.try(&.lock)
      @on_before_fabric_change.try(&.call(FabricMutation::Quarantine, fabric_index))
      @quarantined.add(fabric_index)
      @dirty.delete(fabric_index)
    ensure
      protocol_lock.try(&.unlock)
    end

    def quarantined?(fabric_index : UInt8) : Bool
      @quarantined.includes?(fabric_index) || identity_changed?(fabric_index)
    end

    private def identity_changed?(fabric_index : UInt8) : Bool
      fabric = @fabrics[fabric_index]?
      identity = @identities[fabric_index]?
      !!(fabric && identity &&
        (fabric.fabric_index != fabric_index || fabric.storage_identity != identity))
    end

    # Find a fabric by fabric_id
    def find_by_fabric_id(fabric_id : UInt64) : Fabric?
      all_fabrics.find { |fabric| fabric.fabric_id == fabric_id }
    end

    # Find a fabric by its identity (root_public_key + fabric_id).
    def find_by_fabric_identity(fabric_id : UInt64, root_public_key : Bytes) : Fabric?
      all_fabrics.find { |fabric| fabric.fabric_id == fabric_id && fabric.root_public_key == root_public_key }
    end

    # Get all fabrics
    def all_fabrics : Array(Fabric)
      @fabrics.compact_map { |index, fabric| fabric unless quarantined?(index) }
    end

    # Get fabric count
    def size : Int32
      @fabrics.size
    end

    # Check if table is empty
    def empty? : Bool
      @fabrics.empty?
    end

    # Check if table is full
    def full? : Bool
      @fabrics.size >= @max_fabrics
    end

    # Get number of available slots
    def available_slots : Int32
      @max_fabrics - @fabrics.size
    end

    # Find next available fabric index (1-254)
    def next_available_index : UInt8?
      (Fabric::MIN_FABRIC_INDEX..Fabric::MAX_FABRIC_INDEX).each do |index|
        return index unless @fabrics.has_key?(index) || quarantined?(index)
      end
      nil
    end

    # Get all fabric indices currently in use
    def used_indices : Array(UInt8)
      @fabrics.keys.sort!
    end

    # Get all fabric descriptors (for Fabrics attribute)
    def fabric_descriptors : Array(FabricDescriptor)
      all_fabrics.map { |fabric| FabricDescriptor.from_fabric(fabric) }
    end

    # Clear all fabrics (used for factory reset)
    def clear_all
      protocol_lock = @protocol_lock
      protocol_lock.try(&.lock)
      @on_before_clear.try(&.call)
      @fabrics.clear
      @identities.clear
      @dirty.clear
      @quarantined.clear
      @backend.clear(COLLECTION)
    ensure
      protocol_lock.try(&.unlock)
    end

    # Mark a fabric as recently used (updates last_used_at). The write is
    # deferred when a `write_debouncer` is attached.
    def mark_fabric_used(fabric_index : UInt8) : Bool
      protocol_lock = @protocol_lock
      protocol_lock.try(&.lock)
      return false if quarantined?(fabric_index)
      fabric = @fabrics[fabric_index]?
      return false unless fabric

      fabric.mark_used
      if debouncer = @write_debouncer
        @dirty[fabric_index] = fabric
        debouncer.trigger
      else
        persist_fabric(fabric)
      end
      true
    ensure
      protocol_lock.try(&.unlock)
    end

    # Writes every fabric deferred by `mark_fabric_used`.
    def flush_pending_writes : Nil
      protocol_lock = @protocol_lock
      protocol_lock.try(&.lock)
      return if @dirty.empty?

      pending = @dirty.dup
      @dirty.clear
      @backend.transaction do
        pending.each do |index, fabric|
          persist_fabric(fabric) unless quarantined?(index)
        end
      end
    ensure
      protocol_lock.try(&.unlock)
    end

    # Writes *fabric* as the `fabrics/<index>` document.
    def write_fabric(fabric : Fabric) : Nil
      protocol_lock = @protocol_lock
      protocol_lock.try(&.lock)
      @on_before_fabric_change.try(&.call(FabricMutation::Update, fabric.fabric_index))
      persist_fabric(fabric)
    ensure
      protocol_lock.try(&.unlock)
    end

    # Call only under the protocol lock after a credential guard, or for the
    # last-used metadata writes needed by CASE while a recovery lease is held.
    private def persist_fabric(fabric : Fabric) : Nil
      if @fabrics.any? { |index, stored| stored.same?(fabric) && index != fabric.fabric_index }
        raise StorageError.new("Fabric index changed while stored in the table")
      end
      if identity = @identities[fabric.fabric_index]?
        raise StorageError.new("Fabric identity changed at index #{fabric.fabric_index}") unless identity == fabric.storage_identity
      end
      @backend.write(COLLECTION, fabric.fabric_index.to_s, fabric.to_document)
    end

    # Load fabrics from storage. A document that cannot be decoded is skipped
    # with a warning so one bad entry does not take the whole table down.
    private def load_from_storage : Nil
      @fabrics.clear
      @identities.clear

      @backend.all(COLLECTION).each do |id, document|
        fabric = Fabric.from_document(document)
        @fabrics[fabric.fabric_index] = fabric
        @identities[fabric.fabric_index] = fabric.storage_identity
      rescue ex
        Log.warn(exception: ex) { "Skipping fabric document #{COLLECTION}/#{id}: cannot be decoded" }
      end

      Log.info { "Loaded #{@fabrics.size} fabric(s) from storage" } unless @fabrics.empty?
    end

    # Validate fabric table consistency
    def validate : Array(String)
      errors = [] of String

      # Check for duplicate fabric identities (root_public_key + fabric_id)
      identities = @fabrics.values.map { |fabric| {fabric.fabric_id, fabric.root_public_key.hexstring} }
      if identities.size != identities.uniq.size
        errors << "Duplicate fabric identities detected"
      end

      # Check fabric index range
      @fabrics.each do |index, fabric|
        if index != fabric.fabric_index
          errors << "Fabric index mismatch: key=#{index}, fabric.fabric_index=#{fabric.fabric_index}"
        end

        unless Fabric::MIN_FABRIC_INDEX <= index <= Fabric::MAX_FABRIC_INDEX
          errors << "Invalid fabric index: #{index}"
        end
      end

      # Check capacity
      if @fabrics.size > @max_fabrics
        errors << "Fabric count (#{@fabrics.size}) exceeds max (#{@max_fabrics})"
      end

      errors
    end

    # Get statistics about fabric usage
    def statistics : Hash(String, Int32 | Float64)
      now = Time.utc
      fabrics_array = @fabrics.values

      active_count = fabrics_array.count { |fabric| !fabric.expired? }
      expired_count = fabrics_array.size - active_count

      ages = fabrics_array.map { |fabric| (now - fabric.created_at).total_seconds }
      avg_age = ages.empty? ? 0.0 : ages.sum / ages.size

      last_used_ages = fabrics_array.map { |fabric| (now - fabric.last_used_at).total_seconds }
      avg_last_used = last_used_ages.empty? ? 0.0 : last_used_ages.sum / last_used_ages.size

      {
        "total_fabrics"         => @fabrics.size,
        "active_fabrics"        => active_count,
        "expired_fabrics"       => expired_count,
        "available_slots"       => available_slots,
        "max_fabrics"           => @max_fabrics.to_i,
        "avg_age_seconds"       => avg_age,
        "avg_last_used_seconds" => avg_last_used,
      }
    end
  end
end
