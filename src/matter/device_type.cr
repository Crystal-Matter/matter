require "./datatype/device_type_id"
require "./datatype/cluster_id"
require "./hex"

module Matter
  # Device type definitions from the Matter specification
  # Each device type defines required and optional clusters
  class DeviceType
    # Common Matter Device Types (Spec Chapter 7)

    # Utility Device Types
    ROOT_NODE                  = 0x0016_u32 # Root Node (endpoint 0)
    POWER_SOURCE               = 0x0011_u32 # Power Source
    OTA_REQUESTOR              = 0x0012_u32 # OTA Requestor
    OTA_PROVIDER               = 0x0014_u32 # OTA Provider
    AGGREGATOR                 = 0x000E_u32 # Aggregator
    BRIDGED_NODE               = 0x0013_u32 # Bridged Node
    JOINT_FABRIC_ADMINISTRATOR = 0x0130_u32 # Joint Fabric Administrator

    # Lighting Device Types
    ON_OFF_LIGHT            = 0x0100_u32 # On/Off Light
    DIMMABLE_LIGHT          = 0x0101_u32 # Dimmable Light
    COLOR_TEMPERATURE_LIGHT = 0x010C_u32 # Color Temperature Light
    EXTENDED_COLOR_LIGHT    = 0x010D_u32 # Extended Color Light

    # Smart Plug/Outlet Device Types
    ON_OFF_PLUG_IN_UNIT   = 0x010A_u32 # On/Off Plug-in Unit
    DIMMABLE_PLUG_IN_UNIT = 0x010B_u32 # Dimmable Plug-in Unit

    # Switch Device Types
    ON_OFF_LIGHT_SWITCH = 0x0103_u32 # On/Off Light Switch
    DIMMER_SWITCH       = 0x0104_u32 # Dimmer Switch
    COLOR_DIMMER_SWITCH = 0x0105_u32 # Color Dimmer Switch
    CONTROL_BRIDGE      = 0x0840_u32 # Control Bridge
    PUMP_CONTROLLER     = 0x0304_u32 # Pump Controller
    PUMP                = 0x0303_u32 # Pump

    # Sensor Device Types
    CONTACT_SENSOR     = 0x0015_u32 # Contact Sensor
    LIGHT_SENSOR       = 0x0106_u32 # Light Sensor
    OCCUPANCY_SENSOR   = 0x0107_u32 # Occupancy Sensor
    TEMPERATURE_SENSOR = 0x0302_u32 # Temperature Sensor
    PRESSURE_SENSOR    = 0x0305_u32 # Pressure Sensor
    FLOW_SENSOR        = 0x0306_u32 # Flow Sensor
    HUMIDITY_SENSOR    = 0x0307_u32 # Humidity Sensor
    AIR_QUALITY_SENSOR = 0x002C_u32 # Air Quality Sensor

    # Closure Device Types
    DOOR_LOCK                  = 0x000A_u32 # Door Lock
    DOOR_LOCK_CONTROLLER       = 0x000B_u32 # Door Lock Controller
    WINDOW_COVERING            = 0x0202_u32 # Window Covering
    WINDOW_COVERING_CONTROLLER = 0x0203_u32 # Window Covering Controller

    # HVAC Device Types
    HEATING_COOLING_UNIT = 0x0300_u32 # Heating/Cooling Unit
    THERMOSTAT           = 0x0301_u32 # Thermostat
    FAN                  = 0x002B_u32 # Fan

    # Media Device Types
    BASIC_VIDEO_PLAYER   = 0x0028_u32 # Basic Video Player
    CASTING_VIDEO_PLAYER = 0x0023_u32 # Casting Video Player
    SPEAKER              = 0x0022_u32 # Speaker
    CONTENT_APP          = 0x0024_u32 # Content App
    CASTING_VIDEO_CLIENT = 0x0029_u32 # Casting Video Client
    VIDEO_REMOTE_CONTROL = 0x002A_u32 # Video Remote Control

    getter device_type_id : DataType::DeviceTypeId
    getter name : String
    getter revision : UInt16
    getter required_server_clusters : Array(UInt32)
    getter optional_server_clusters : Array(UInt32)

    def initialize(
      @device_type_id : DataType::DeviceTypeId,
      @name : String,
      @revision : UInt16,
      @required_server_clusters : Array(UInt32) = [] of UInt32,
      @optional_server_clusters : Array(UInt32) = [] of UInt32,
    )
    end

    # Factory methods for common device types

    def self.root_node : DeviceType
      new(
        DataType::DeviceTypeId.new(ROOT_NODE),
        "Root Node",
        1_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0028_u32, # Basic Information
          0x0030_u32, # General Commissioning
          0x0031_u32, # Network Commissioning
          0x003C_u32, # General Diagnostics
          0x003E_u32, # Administrator Commissioning
          0x003F_u32, # Operational Credentials
          0x0033_u32, # Group Key Management
        ],
        optional_server_clusters: [
          0x0003_u32, # Identify
        ]
      )
    end

    def self.joint_fabric_administrator : DeviceType
      new(
        DataType::DeviceTypeId.new(JOINT_FABRIC_ADMINISTRATOR),
        "Joint Fabric Administrator",
        1_u16,
        required_server_clusters: [0x0752_u32, 0x0753_u32]
      )
    end

    def self.on_off_light : DeviceType
      new(
        DataType::DeviceTypeId.new(ON_OFF_LIGHT),
        "On/Off Light",
        2_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0003_u32, # Identify
          0x0004_u32, # Groups
          0x0006_u32, # On/Off
        ],
        optional_server_clusters: [
          0x0008_u32, # Level Control (for compatibility)
          0x0062_u32, # Scenes Management
        ]
      )
    end

    def self.dimmable_light : DeviceType
      new(
        DataType::DeviceTypeId.new(DIMMABLE_LIGHT),
        "Dimmable Light",
        2_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0003_u32, # Identify
          0x0004_u32, # Groups
          0x0006_u32, # On/Off
          0x0008_u32, # Level Control
        ],
        optional_server_clusters: [
          0x0062_u32, # Scenes Management
        ]
      )
    end

    def self.on_off_plug_in_unit : DeviceType
      new(
        DataType::DeviceTypeId.new(ON_OFF_PLUG_IN_UNIT),
        "On/Off Plug-in Unit",
        2_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0003_u32, # Identify
          0x0004_u32, # Groups
          0x0006_u32, # On/Off
        ],
        optional_server_clusters: [
          0x0008_u32, # Level Control
          0x0062_u32, # Scenes Management
        ]
      )
    end

    def self.on_off_light_switch : DeviceType
      new(
        DataType::DeviceTypeId.new(ON_OFF_LIGHT_SWITCH),
        "On/Off Light Switch",
        2_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0003_u32, # Identify
        ],
        optional_server_clusters: [] of UInt32
      )
    end

    def self.dimmer_switch : DeviceType
      new(
        DataType::DeviceTypeId.new(DIMMER_SWITCH),
        "Dimmer Switch",
        2_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0003_u32, # Identify
        ],
        optional_server_clusters: [] of UInt32
      )
    end

    def self.contact_sensor : DeviceType
      new(
        DataType::DeviceTypeId.new(CONTACT_SENSOR),
        "Contact Sensor",
        1_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0003_u32, # Identify
          0x0045_u32, # Boolean State
        ],
        optional_server_clusters: [] of UInt32
      )
    end

    def self.temperature_sensor : DeviceType
      new(
        DataType::DeviceTypeId.new(TEMPERATURE_SENSOR),
        "Temperature Sensor",
        2_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0003_u32, # Identify
          0x0402_u32, # Temperature Measurement
        ],
        optional_server_clusters: [] of UInt32
      )
    end

    def self.air_quality_sensor : DeviceType
      new(
        DataType::DeviceTypeId.new(AIR_QUALITY_SENSOR),
        "Air Quality Sensor",
        1_u16,
        required_server_clusters: [0x001D_u32, 0x0003_u32, 0x005B_u32],
        optional_server_clusters: [
          0x0402_u32, 0x0405_u32, 0x040C_u32, 0x040D_u32, 0x0413_u32,
          0x0415_u32, 0x042A_u32, 0x042B_u32, 0x042C_u32, 0x042D_u32,
          0x042E_u32, 0x042F_u32,
        ]
      )
    end

    def self.door_lock : DeviceType
      new(
        DataType::DeviceTypeId.new(DOOR_LOCK),
        "Door Lock",
        2_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0003_u32, # Identify
          0x0101_u32, # Door Lock
        ],
        optional_server_clusters: [] of UInt32
      )
    end

    def self.thermostat : DeviceType
      new(
        DataType::DeviceTypeId.new(THERMOSTAT),
        "Thermostat",
        2_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0003_u32, # Identify
          0x0004_u32, # Groups
          0x0201_u32, # Thermostat
        ],
        optional_server_clusters: [
          0x0204_u32, # Thermostat User Interface Configuration
          0x0402_u32, # Temperature Measurement
          0x0062_u32, # Scenes Management
        ]
      )
    end

    def self.fan : DeviceType
      new(
        DataType::DeviceTypeId.new(FAN),
        "Fan",
        3_u16,
        required_server_clusters: [
          0x001D_u32, # Descriptor
          0x0003_u32, # Identify
          0x0004_u32, # Groups
          0x0202_u32, # Fan Control
        ],
        optional_server_clusters: [
          0x0006_u32, # On/Off
        ]
      )
    end

    # Revision reported for a device type this library has no definition for.
    # Every Matter device type starts at revision 1.
    UNKNOWN_REVISION = 1_u16

    # The definition for *device_type*, or a bare definition carrying just the
    # id (no mandatory clusters, revision `UNKNOWN_REVISION`) when this library
    # has no table entry for it. Endpoints built from a raw device type id go
    # through here, so an unknown id costs conformance checking but never
    # refuses to boot.
    def self.for(device_type : UInt32) : DeviceType
      case device_type
      when ROOT_NODE                  then root_node
      when JOINT_FABRIC_ADMINISTRATOR then joint_fabric_administrator
      when ON_OFF_LIGHT               then on_off_light
      when DIMMABLE_LIGHT             then dimmable_light
      when ON_OFF_PLUG_IN_UNIT        then on_off_plug_in_unit
      when ON_OFF_LIGHT_SWITCH        then on_off_light_switch
      when DIMMER_SWITCH              then dimmer_switch
      when CONTACT_SENSOR             then contact_sensor
      when TEMPERATURE_SENSOR         then temperature_sensor
      when AIR_QUALITY_SENSOR         then air_quality_sensor
      when DOOR_LOCK                  then door_lock
      when THERMOSTAT                 then thermostat
      when FAN                        then fan
      else
        new(
          DataType::DeviceTypeId.new(device_type),
          name(device_type) || "Device Type #{Hex.u32(device_type)}",
          UNKNOWN_REVISION
        )
      end
    end

    # Human-readable name for a device type id, `nil` when unknown
    def self.name(device_type : UInt32) : String?
      case device_type
      when ROOT_NODE                  then "Root Node"
      when JOINT_FABRIC_ADMINISTRATOR then "Joint Fabric Administrator"
      when POWER_SOURCE               then "Power Source"
      when OTA_REQUESTOR              then "OTA Requestor"
      when OTA_PROVIDER               then "OTA Provider"
      when AGGREGATOR                 then "Aggregator"
      when BRIDGED_NODE               then "Bridged Node"
      when ON_OFF_LIGHT               then "On/Off Light"
      when DIMMABLE_LIGHT             then "Dimmable Light"
      when COLOR_TEMPERATURE_LIGHT    then "Color Temperature Light"
      when EXTENDED_COLOR_LIGHT       then "Extended Color Light"
      when ON_OFF_PLUG_IN_UNIT        then "On/Off Plug-in Unit"
      when DIMMABLE_PLUG_IN_UNIT      then "Dimmable Plug-in Unit"
      when ON_OFF_LIGHT_SWITCH        then "On/Off Light Switch"
      when DIMMER_SWITCH              then "Dimmer Switch"
      when COLOR_DIMMER_SWITCH        then "Color Dimmer Switch"
      when CONTROL_BRIDGE             then "Control Bridge"
      when PUMP_CONTROLLER            then "Pump Controller"
      when PUMP                       then "Pump"
      when CONTACT_SENSOR             then "Contact Sensor"
      when LIGHT_SENSOR               then "Light Sensor"
      when OCCUPANCY_SENSOR           then "Occupancy Sensor"
      when TEMPERATURE_SENSOR         then "Temperature Sensor"
      when PRESSURE_SENSOR            then "Pressure Sensor"
      when FLOW_SENSOR                then "Flow Sensor"
      when HUMIDITY_SENSOR            then "Humidity Sensor"
      when AIR_QUALITY_SENSOR         then "Air Quality Sensor"
      when DOOR_LOCK                  then "Door Lock"
      when DOOR_LOCK_CONTROLLER       then "Door Lock Controller"
      when WINDOW_COVERING            then "Window Covering"
      when WINDOW_COVERING_CONTROLLER then "Window Covering Controller"
      when HEATING_COOLING_UNIT       then "Heating/Cooling Unit"
      when THERMOSTAT                 then "Thermostat"
      when FAN                        then "Fan"
      when BASIC_VIDEO_PLAYER         then "Basic Video Player"
      when CASTING_VIDEO_PLAYER       then "Casting Video Player"
      when SPEAKER                    then "Speaker"
      when CONTENT_APP                then "Content App"
      when CASTING_VIDEO_CLIENT       then "Casting Video Client"
      when VIDEO_REMOTE_CONTROL       then "Video Remote Control"
      end
    end

    # Helper method to check if a cluster is required
    def requires_cluster?(cluster_id : UInt32) : Bool
      @required_server_clusters.includes?(cluster_id)
    end

    # Helper method to check if a cluster is optional
    def supports_optional_cluster?(cluster_id : UInt32) : Bool
      @optional_server_clusters.includes?(cluster_id)
    end

    # Helper method to check if a cluster is allowed (required or optional)
    def allows_cluster?(cluster_id : UInt32) : Bool
      requires_cluster?(cluster_id) || supports_optional_cluster?(cluster_id)
    end
  end
end
