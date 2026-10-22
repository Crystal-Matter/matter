require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Ecosystem Information (0x0750). A bridge may publish metadata
    # supplied by its host application after that application's consent flow.
    # Empty directories explicitly mean that no metadata is available.
    class EcosystemInformation < Base
      cluster 0x0750, revision: 1, persist_state: false

      MAX_DEVICE_NAME_BYTES       =  64
      MAX_LOCATION_ID_BYTES       =  64
      MAX_LOCATION_NAME_BYTES     = 128
      MAX_LOCATION_IDS_PER_DEVICE =  64

      struct DeviceTypeStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property device_type : UInt32

        @[TLV::Field(tag: 1)]
        property revision : UInt16

        def initialize(@device_type : UInt32, @revision : UInt16)
        end
      end

      struct LocationDescriptorStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property location_name : String

        @[TLV::Field(tag: 1)]
        property floor_number : Int16?

        @[TLV::Field(tag: 2)]
        property area_type : UInt8?

        def initialize(@location_name : String, @floor_number : Int16?, @area_type : UInt8?)
        end
      end

      struct EcosystemDeviceStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, optional: true)]
        property device_name : String?

        @[TLV::Field(tag: 1, optional: true)]
        property device_name_last_edit : UInt64?

        @[TLV::Field(tag: 2, optional: true)]
        property bridged_endpoint : UInt16?

        @[TLV::Field(tag: 3, optional: true)]
        property original_endpoint : UInt16?

        @[TLV::Field(tag: 4)]
        property device_types : Array(DeviceTypeStruct)

        @[TLV::Field(tag: 5)]
        property unique_location_ids : Array(String)

        @[TLV::Field(tag: 6)]
        property unique_location_ids_last_edit : UInt64

        @[TLV::Field(tag: 254)]
        property fabric_index : UInt8

        def initialize(
          @device_name : String?,
          @device_name_last_edit : UInt64?,
          @bridged_endpoint : UInt16?,
          @original_endpoint : UInt16?,
          @device_types : Array(DeviceTypeStruct),
          @unique_location_ids : Array(String),
          @unique_location_ids_last_edit : UInt64,
          @fabric_index : UInt8,
        )
        end
      end

      struct EcosystemLocationStruct
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property unique_location_id : String

        @[TLV::Field(tag: 1)]
        property location_descriptor : LocationDescriptorStruct

        @[TLV::Field(tag: 2)]
        property location_descriptor_last_edit : UInt64

        @[TLV::Field(tag: 254)]
        property fabric_index : UInt8

        def initialize(
          @unique_location_id : String,
          @location_descriptor : LocationDescriptorStruct,
          @location_descriptor_last_edit : UInt64,
          @fabric_index : UInt8,
        )
        end
      end

      struct PersistedState
        include Storage::Record

        getter data_version : UInt32
        getter device_directory : Array(EcosystemDeviceStruct)
        getter location_directory : Array(EcosystemLocationStruct)

        def initialize(@data_version, @device_directory, @location_directory)
        end
      end

      attribute 0x0000, :device_directory, Array(EcosystemDeviceStruct), computed: true,
        read_access: :manage, fabric_scoped: true
      attribute 0x0001, :location_directory, Array(EcosystemLocationStruct), computed: true,
        read_access: :manage, fabric_scoped: true

      @device_directory = [] of EcosystemDeviceStruct
      @location_directory = [] of EcosystemLocationStruct

      # Installed by Device before restoring state. Standalone cluster tests can
      # leave it unset, but a serving device must never publish for an index it
      # does not currently own.
      property fabric_installed : Proc(UInt8, Bool)?

      def device_directory(fabric_index : UInt8?) : Array(EcosystemDeviceStruct) | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless fabric_index
        entries = request_fabric_filtered? ? @device_directory.select(&.fabric_index.==(fabric_index)) : @device_directory
        entries.map { |entry| EcosystemDeviceStruct.from_document(entry.to_document) }
      end

      def location_directory(fabric_index : UInt8?) : Array(EcosystemLocationStruct) | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless fabric_index
        entries = request_fabric_filtered? ? @location_directory.select(&.fabric_index.==(fabric_index)) : @location_directory
        entries.map { |entry| EcosystemLocationStruct.from_document(entry.to_document) }
      end

      # Replaces this fabric's published view. The host application is responsible
      # for obtaining consent before calling this API; the cluster never gathers
      # or derives private name/location metadata on its own.
      def publish(fabric_index : UInt8, devices : Array(EcosystemDeviceStruct), locations : Array(EcosystemLocationStruct)) : Nil
        validate_publication(fabric_index, devices, locations)
        if checker = @fabric_installed
          raise ConfigurationError.new("Cannot publish Ecosystem Information for an absent fabric") unless checker.call(fabric_index)
        end
        copied_devices = devices.map { |entry| EcosystemDeviceStruct.from_document(entry.to_document) }
        copied_locations = locations.map { |entry| EcosystemLocationStruct.from_document(entry.to_document) }
        @device_directory.reject!(&.fabric_index.==(fabric_index))
        @location_directory.reject!(&.fabric_index.==(fabric_index))
        @device_directory.concat(copied_devices)
        @location_directory.concat(copied_locations)
        increment_version_and_notify(ATTR_DEVICE_DIRECTORY)
        notify_changed(ATTR_LOCATION_DIRECTORY)
      end

      # Erase private metadata when a fabric is removed from the node.
      def remove_fabric(fabric_index : UInt8) : Nil
        before = @device_directory.size + @location_directory.size
        @device_directory.reject!(&.fabric_index.==(fabric_index))
        @location_directory.reject!(&.fabric_index.==(fabric_index))
        return if @device_directory.size + @location_directory.size == before
        increment_version_and_notify(ATTR_DEVICE_DIRECTORY)
        notify_changed(ATTR_LOCATION_DIRECTORY)
      end

      def save_state : Storage::Document?
        PersistedState.new(@data_version, @device_directory, @location_directory).to_document
      end

      def restore_state(document : Storage::Document) : Nil
        state = PersistedState.from_document(document)
        devices = state.device_directory.select { |entry| fabric_still_installed?(entry.fabric_index) }
        locations = state.location_directory.select { |entry| fabric_still_installed?(entry.fabric_index) }
        devices.group_by(&.fabric_index).each do |fabric_index, entries|
          validate_publication(fabric_index, entries, locations.select(&.fabric_index.==(fabric_index)))
        end
        locations.group_by(&.fabric_index).each do |fabric_index, entries|
          next if devices.any?(&.fabric_index.==(fabric_index))
          validate_publication(fabric_index, [] of EcosystemDeviceStruct, entries)
        end
        @data_version = state.data_version
        @device_directory = devices
        @location_directory = locations
        if devices.size != state.device_directory.size || locations.size != state.location_directory.size
          increment_version_and_notify(ATTR_DEVICE_DIRECTORY)
          notify_changed(ATTR_LOCATION_DIRECTORY)
        end
      end

      private def fabric_still_installed?(fabric_index : UInt8) : Bool
        @fabric_installed.try(&.call(fabric_index)) != false
      end

      private def validate_publication(fabric_index : UInt8, devices : Array(EcosystemDeviceStruct), locations : Array(EcosystemLocationStruct)) : Nil
        if !(Fabric::MIN_FABRIC_INDEX..Fabric::MAX_FABRIC_INDEX).includes?(fabric_index) ||
           devices.any? { |entry| entry.fabric_index != fabric_index } ||
           locations.any? { |entry| entry.fabric_index != fabric_index }
          raise ConfigurationError.new("Ecosystem Information entries must belong to the published fabric")
        end

        location_ids = locations.map(&.unique_location_id)
        if location_ids.uniq.size != location_ids.size
          raise ConfigurationError.new("Ecosystem Information location IDs must be unique")
        end
        locations.each do |entry|
          if entry.unique_location_id.bytesize > MAX_LOCATION_ID_BYTES || entry.location_descriptor.location_name.bytesize > MAX_LOCATION_NAME_BYTES
            raise ConfigurationError.new("Ecosystem Information location text exceeds Matter limits")
          end
        end
        devices.each do |entry|
          if (name = entry.device_name) && name.bytesize > MAX_DEVICE_NAME_BYTES
            raise ConfigurationError.new("Ecosystem Information device name exceeds Matter limit")
          end
          if !entry.device_name.nil? && entry.device_name_last_edit.nil?
            raise ConfigurationError.new("Ecosystem Information named device requires last-edit time")
          end
          if entry.device_types.any?(&.revision.==(0_u16)) ||
             entry.unique_location_ids.size > MAX_LOCATION_IDS_PER_DEVICE ||
             entry.unique_location_ids.uniq.size != entry.unique_location_ids.size ||
             entry.unique_location_ids.any? { |id| id.bytesize > MAX_LOCATION_ID_BYTES }
            raise ConfigurationError.new("Ecosystem Information device entry is invalid")
          end
        end
      end
    end
  end
end
