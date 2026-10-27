require "./datatype/device_type_id"
require "./datatype/cluster_id"
require "./cluster"
require "./hex"

module Matter
  # Device type definitions from the Matter specification
  # Each device type defines required and optional clusters and may require
  # specific attributes in one of its server clusters.
  class DeviceType
    # Common Matter Device Types (Spec Chapter 7)

    # Utility Device Types
    ROOT_NODE                  = 0x0016_u32 # Root Node (endpoint 0)
    POWER_SOURCE               = 0x0011_u32 # Power Source
    OTA_REQUESTOR              = 0x0012_u32 # OTA Requestor
    OTA_PROVIDER               = 0x0014_u32 # OTA Provider
    AGGREGATOR                 = 0x000E_u32 # Aggregator
    BRIDGED_NODE               = 0x0013_u32 # Bridged Node
    BRIDGED_NODE_REVISION      =      3_u16 # Matter 1.6
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
    CONTACT_SENSOR           = 0x0015_u32 # Contact Sensor
    LIGHT_SENSOR             = 0x0106_u32 # Light Sensor
    OCCUPANCY_SENSOR         = 0x0107_u32 # Occupancy Sensor
    TEMPERATURE_SENSOR       = 0x0302_u32 # Temperature Sensor
    PRESSURE_SENSOR          = 0x0305_u32 # Pressure Sensor
    FLOW_SENSOR              = 0x0306_u32 # Flow Sensor
    HUMIDITY_SENSOR          = 0x0307_u32 # Humidity Sensor
    AIR_QUALITY_SENSOR       = 0x002C_u32 # Air Quality Sensor
    SMOKE_CO_ALARM           = 0x0076_u32 # Smoke CO Alarm
    SOIL_SENSOR              = 0x0045_u32 # Soil Sensor
    ELECTRICAL_UTILITY_METER = 0x0511_u32 # Electrical Utility Meter

    # Appliance Device Types
    REFRIGERATOR                   = 0x0070_u32 # Refrigerator
    TEMPERATURE_CONTROLLED_CABINET = 0x0071_u32 # Temperature Controlled Cabinet
    DISHWASHER                     = 0x0075_u32 # Dishwasher
    MICROWAVE_OVEN                 = 0x0079_u32 # Microwave Oven
    ROBOTIC_VACUUM_CLEANER         = 0x0074_u32 # Robotic Vacuum Cleaner

    # Closure Device Types
    DOOR_LOCK                  = 0x000A_u32 # Door Lock
    DOOR_LOCK_CONTROLLER       = 0x000B_u32 # Door Lock Controller
    WINDOW_COVERING            = 0x0202_u32 # Window Covering
    WINDOW_COVERING_CONTROLLER = 0x0203_u32 # Window Covering Controller
    CLOSURE                    = 0x0230_u32 # Closure (Matter 1.6)
    CLOSURE_PANEL              = 0x0231_u32 # Closure Panel (Matter 1.6)

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
    CAMERA               = 0x0142_u32 # Camera (Matter 1.6)

    getter device_type_id : DataType::DeviceTypeId
    getter name : String
    getter revision : UInt16
    getter required_server_clusters : Array(UInt32)
    getter required_client_clusters : Array(UInt32)
    getter optional_server_clusters : Array(UInt32)
    getter required_server_attributes : Hash(UInt32, Array(UInt32))
    # Device types which must also appear somewhere on the node.
    getter required_node_device_types : Array(UInt32)
    getter required_endpoint_device_types : Array(UInt32)
    getter required_server_features : Hash(UInt32, UInt32)
    getter forbidden_server_features : Hash(UInt32, UInt32)
    getter required_server_events : Hash(UInt32, Array(UInt32))
    getter forbidden_server_attributes : Hash(UInt32, Array(UInt32))

    def initialize(
      @device_type_id : DataType::DeviceTypeId,
      @name : String,
      @revision : UInt16,
      @required_server_clusters : Array(UInt32) = [] of UInt32,
      @optional_server_clusters : Array(UInt32) = [] of UInt32,
      @required_server_attributes : Hash(UInt32, Array(UInt32)) = {} of UInt32 => Array(UInt32),
      @required_node_device_types : Array(UInt32) = [] of UInt32,
      @required_client_clusters : Array(UInt32) = [] of UInt32,
      @required_endpoint_device_types : Array(UInt32) = [] of UInt32,
      @required_server_features : Hash(UInt32, UInt32) = {} of UInt32 => UInt32,
      @forbidden_server_features : Hash(UInt32, UInt32) = {} of UInt32 => UInt32,
      @required_server_events : Hash(UInt32, Array(UInt32)) = {} of UInt32 => Array(UInt32),
      @forbidden_server_attributes : Hash(UInt32, Array(UInt32)) = {} of UInt32 => Array(UInt32),
    )
    end

    # Factory methods for common device types

    def self.root_node : DeviceType
      new(
        DataType::DeviceTypeId.new(ROOT_NODE),
        "Root Node",
        1_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::BasicInformation::CLUSTER_ID,
          Cluster::GeneralCommissioning::CLUSTER_ID,
          Cluster::NetworkCommissioning::CLUSTER_ID,
          Cluster::AdministratorCommissioning::CLUSTER_ID,
          Cluster::OperationalCredentials::CLUSTER_ID,
          Cluster::GroupKeyManagement::CLUSTER_ID,
          Cluster::GeneralDiagnostics::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::Identify::CLUSTER_ID,
        ]
      )
    end

    def self.joint_fabric_administrator : DeviceType
      new(
        DataType::DeviceTypeId.new(JOINT_FABRIC_ADMINISTRATOR),
        "Joint Fabric Administrator",
        1_u16,
        required_server_clusters: [Cluster::JointFabricDatastore::CLUSTER_ID, Cluster::JointFabricAdministrator::CLUSTER_ID]
      )
    end

    # Bridged Node revision 3. FabricSynchronizedNode adds Administrator
    # Commissioning and makes Ecosystem Information mandatory; Endpoint checks
    # that condition against the installed bridged commissioning implementation.
    def self.bridged_node : DeviceType
      new(
        DataType::DeviceTypeId.new(BRIDGED_NODE),
        "Bridged Node",
        BRIDGED_NODE_REVISION,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::BridgedDeviceBasicInformation::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::AdministratorCommissioning::CLUSTER_ID,
          Cluster::EcosystemInformation::CLUSTER_ID,
          Cluster::PowerSource::CLUSTER_ID,
        ]
      )
    end

    def self.power_source : DeviceType
      new(
        DataType::DeviceTypeId.new(POWER_SOURCE),
        "Power Source",
        1_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::PowerSource::CLUSTER_ID,
        ]
      )
    end

    # Matter 1.6 Refrigerator requires a Temperature Controlled Cabinet on
    # the same endpoint with the physical Cooler condition.
    def self.refrigerator : DeviceType
      new(
        DataType::DeviceTypeId.new(REFRIGERATOR), "Refrigerator", 3_u16,
        required_server_clusters: [Cluster::Descriptor::CLUSTER_ID],
        optional_server_clusters: [Cluster::Identify::CLUSTER_ID, Cluster::RefrigeratorAndTemperatureControlledCabinetMode::CLUSTER_ID, Cluster::RefrigeratorAlarm::CLUSTER_ID, Cluster::ActivatedCarbonFilterMonitoring::CLUSTER_ID],
        required_endpoint_device_types: [TEMPERATURE_CONTROLLED_CABINET],
        forbidden_server_features: {Cluster::RefrigeratorAndTemperatureControlledCabinetMode::CLUSTER_ID => Cluster::ModeBase::Feature::DependentOnOff.value},
        forbidden_server_attributes: {Cluster::RefrigeratorAndTemperatureControlledCabinetMode::CLUSTER_ID => [Cluster::ModeBase::ATTR_START_UP_MODE]}
      )
    end

    def self.temperature_controlled_cabinet : DeviceType
      new(
        DataType::DeviceTypeId.new(TEMPERATURE_CONTROLLED_CABINET),
        "Temperature Controlled Cabinet", 6_u16,
        required_server_clusters: [Cluster::Descriptor::CLUSTER_ID, Cluster::TemperatureControl::CLUSTER_ID],
        optional_server_clusters: [Cluster::OvenCavityOperationalState::CLUSTER_ID, Cluster::OvenMode::CLUSTER_ID, Cluster::RefrigeratorAndTemperatureControlledCabinetMode::CLUSTER_ID, Cluster::TemperatureAlarm::CLUSTER_ID, Cluster::TemperatureMeasurement::CLUSTER_ID],
        required_server_features: {Cluster::TemperatureControl::CLUSTER_ID => Cluster::TemperatureControl::Feature::TemperatureNumber.value},
        forbidden_server_features: {
          Cluster::OvenMode::CLUSTER_ID                                        => Cluster::ModeBase::Feature::DependentOnOff.value,
          Cluster::RefrigeratorAndTemperatureControlledCabinetMode::CLUSTER_ID => Cluster::ModeBase::Feature::DependentOnOff.value,
          Cluster::TemperatureControl::CLUSTER_ID                              => Cluster::TemperatureControl::Feature::TemperatureLevel.value,
        },
        required_server_events: {Cluster::OvenCavityOperationalState::CLUSTER_ID => [Cluster::OvenCavityOperationalState::EVENT_OPERATION_COMPLETION]}, # OperationCompletion if present
        forbidden_server_attributes: {
        Cluster::OvenMode::CLUSTER_ID                                        => [Cluster::ModeBase::ATTR_START_UP_MODE],
        Cluster::RefrigeratorAndTemperatureControlledCabinetMode::CLUSTER_ID => [Cluster::ModeBase::ATTR_START_UP_MODE],
      }
      )
    end

    def self.dishwasher : DeviceType
      new(
        DataType::DeviceTypeId.new(DISHWASHER), "Dishwasher", 2_u16,
        required_server_clusters: [Cluster::Descriptor::CLUSTER_ID, Cluster::OperationalState::CLUSTER_ID],
        optional_server_clusters: [Cluster::Identify::CLUSTER_ID, Cluster::OnOff::CLUSTER_ID, Cluster::TemperatureControl::CLUSTER_ID, Cluster::DishwasherMode::CLUSTER_ID, Cluster::DishwasherAlarm::CLUSTER_ID],
        required_server_features: {Cluster::OnOff::CLUSTER_ID => Cluster::OnOff::Feature::DeadFrontBehavior.value}, # DF, if On/Off present
        forbidden_server_features: {Cluster::DishwasherMode::CLUSTER_ID => Cluster::ModeBase::Feature::DependentOnOff.value},
        required_server_events: {Cluster::OperationalState::CLUSTER_ID => [Cluster::OperationalState::EVENT_OPERATION_COMPLETION]},
        forbidden_server_attributes: {Cluster::DishwasherMode::CLUSTER_ID => [Cluster::ModeBase::ATTR_START_UP_MODE]}
      )
    end

    def self.robotic_vacuum_cleaner : DeviceType
      new(
        DataType::DeviceTypeId.new(ROBOTIC_VACUUM_CLEANER), "Robotic Vacuum Cleaner", 4_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
          Cluster::RvcRunMode::CLUSTER_ID,
          Cluster::RvcOperationalState::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::RvcCleanMode::CLUSTER_ID,
          Cluster::ServiceArea::CLUSTER_ID,
        ],
        required_server_events: {Cluster::RvcOperationalState::CLUSTER_ID => [Cluster::RvcOperationalState::EVENT_OPERATION_COMPLETION]}
      )
    end

    def self.camera : DeviceType
      new(
        DataType::DeviceTypeId.new(CAMERA),
        "Camera",
        1_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::CameraAvStreamManagement::CLUSTER_ID, # Camera AV Stream Management (ADO, VDO, SNP)
          Cluster::WebRtcTransportProvider::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::Identify::CLUSTER_ID,
          Cluster::OccupancySensing::CLUSTER_ID,
          Cluster::ZoneManagement::CLUSTER_ID, # Zone Management (TWODCART)
          Cluster::CameraAvSettingsUserLevelManagement::CLUSTER_ID,
          Cluster::WebRtcTransportRequestor::CLUSTER_ID,
          Cluster::PushAvStreamTransport::CLUSTER_ID,
        ],
        required_node_device_types: [ROOT_NODE, POWER_SOURCE],
        required_client_clusters: [Cluster::WebRtcTransportRequestor::CLUSTER_ID]
      )
    end

    def self.smoke_co_alarm : DeviceType
      new(
        DataType::DeviceTypeId.new(SMOKE_CO_ALARM),
        "Smoke CO Alarm",
        2_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
          Cluster::SmokeCOAlarm::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::Groups::CLUSTER_ID,
          Cluster::TemperatureMeasurement::CLUSTER_ID,
          Cluster::RelativeHumidityMeasurement::CLUSTER_ID,
          Cluster::CarbonMonoxideConcentrationMeasurement::CLUSTER_ID,
        ],
        required_node_device_types: [POWER_SOURCE]
      )
    end

    def self.on_off_light : DeviceType
      new(
        DataType::DeviceTypeId.new(ON_OFF_LIGHT),
        "On/Off Light",
        2_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
          Cluster::Groups::CLUSTER_ID,
          Cluster::OnOff::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::LevelControl::CLUSTER_ID, # Level Control (for compatibility)
          Cluster::ScenesManagement::CLUSTER_ID,
        ]
      )
    end

    def self.dimmable_light : DeviceType
      new(
        DataType::DeviceTypeId.new(DIMMABLE_LIGHT),
        "Dimmable Light",
        2_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
          Cluster::Groups::CLUSTER_ID,
          Cluster::OnOff::CLUSTER_ID,
          Cluster::LevelControl::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::ScenesManagement::CLUSTER_ID,
        ]
      )
    end

    def self.on_off_plug_in_unit : DeviceType
      new(
        DataType::DeviceTypeId.new(ON_OFF_PLUG_IN_UNIT),
        "On/Off Plug-in Unit",
        2_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
          Cluster::Groups::CLUSTER_ID,
          Cluster::OnOff::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::LevelControl::CLUSTER_ID,
          Cluster::ScenesManagement::CLUSTER_ID,
        ]
      )
    end

    def self.on_off_light_switch : DeviceType
      new(
        DataType::DeviceTypeId.new(ON_OFF_LIGHT_SWITCH),
        "On/Off Light Switch",
        2_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
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
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
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
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
          Cluster::BooleanState::CLUSTER_ID,
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
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
          Cluster::TemperatureMeasurement::CLUSTER_ID,
        ],
        optional_server_clusters: [] of UInt32
      )
    end

    def self.air_quality_sensor : DeviceType
      new(
        DataType::DeviceTypeId.new(AIR_QUALITY_SENSOR),
        "Air Quality Sensor",
        1_u16,
        required_server_clusters: [Cluster::Descriptor::CLUSTER_ID, Cluster::Identify::CLUSTER_ID, Cluster::AirQuality::CLUSTER_ID],
        optional_server_clusters: [
          Cluster::TemperatureMeasurement::CLUSTER_ID, Cluster::RelativeHumidityMeasurement::CLUSTER_ID, Cluster::CarbonMonoxideConcentrationMeasurement::CLUSTER_ID, Cluster::CarbonDioxideConcentrationMeasurement::CLUSTER_ID, Cluster::NitrogenDioxideConcentrationMeasurement::CLUSTER_ID,
          Cluster::OzoneConcentrationMeasurement::CLUSTER_ID, Cluster::Pm25ConcentrationMeasurement::CLUSTER_ID, Cluster::FormaldehydeConcentrationMeasurement::CLUSTER_ID, Cluster::Pm1ConcentrationMeasurement::CLUSTER_ID, Cluster::Pm10ConcentrationMeasurement::CLUSTER_ID,
          Cluster::TotalVolatileOrganicCompoundsConcentrationMeasurement::CLUSTER_ID, Cluster::RadonConcentrationMeasurement::CLUSTER_ID,
        ]
      )
    end

    def self.soil_sensor : DeviceType
      new(
        DataType::DeviceTypeId.new(SOIL_SENSOR),
        "Soil Sensor",
        1_u16,
        required_server_clusters: [Cluster::Descriptor::CLUSTER_ID, Cluster::Identify::CLUSTER_ID, Cluster::SoilMeasurement::CLUSTER_ID],
        optional_server_clusters: [Cluster::TemperatureMeasurement::CLUSTER_ID]
      )
    end

    def self.microwave_oven : DeviceType
      new(
        DataType::DeviceTypeId.new(MICROWAVE_OVEN),
        "Microwave Oven",
        2_u16,
        required_server_clusters: [Cluster::Descriptor::CLUSTER_ID, Cluster::OperationalState::CLUSTER_ID, Cluster::MicrowaveOvenMode::CLUSTER_ID, Cluster::MicrowaveOvenControl::CLUSTER_ID],
        optional_server_clusters: [Cluster::Identify::CLUSTER_ID, Cluster::FanControl::CLUSTER_ID],
        required_server_attributes: {Cluster::OperationalState::CLUSTER_ID => [Cluster::OperationalState::ATTR_COUNTDOWN_TIME]}
      )
    end

    def self.electrical_utility_meter : DeviceType
      new(
        DataType::DeviceTypeId.new(ELECTRICAL_UTILITY_METER),
        "Electrical Utility Meter",
        1_u16,
        required_server_clusters: [Cluster::Descriptor::CLUSTER_ID, Cluster::MeterIdentification::CLUSTER_ID]
      )
    end

    def self.door_lock : DeviceType
      new(
        DataType::DeviceTypeId.new(DOOR_LOCK),
        "Door Lock",
        2_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
          Cluster::DoorLock::CLUSTER_ID,
        ],
        optional_server_clusters: [] of UInt32
      )
    end

    def self.closure : DeviceType
      new(
        DataType::DeviceTypeId.new(CLOSURE),
        "Closure",
        1_u16,
        required_server_clusters: [Cluster::Descriptor::CLUSTER_ID, Cluster::Identify::CLUSTER_ID, Cluster::ClosureControl::CLUSTER_ID]
      )
    end

    def self.closure_panel : DeviceType
      new(
        DataType::DeviceTypeId.new(CLOSURE_PANEL),
        "Closure Panel",
        1_u16,
        required_server_clusters: [Cluster::Descriptor::CLUSTER_ID, Cluster::ClosureDimension::CLUSTER_ID]
      )
    end

    def self.thermostat : DeviceType
      new(
        DataType::DeviceTypeId.new(THERMOSTAT),
        "Thermostat",
        2_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
          Cluster::Groups::CLUSTER_ID,
          Cluster::Thermostat::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::ThermostatUserInterfaceConfiguration::CLUSTER_ID,
          Cluster::TemperatureMeasurement::CLUSTER_ID,
          Cluster::ScenesManagement::CLUSTER_ID,
        ]
      )
    end

    def self.fan : DeviceType
      new(
        DataType::DeviceTypeId.new(FAN),
        "Fan",
        3_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::Identify::CLUSTER_ID,
          Cluster::Groups::CLUSTER_ID,
          Cluster::FanControl::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::OnOff::CLUSTER_ID,
        ]
      )
    end

    # Matter 1.6 revision 2 Basic Video Player. Content Control is provisional
    # and optional; the media host enforces it before or during playback.
    def self.basic_video_player : DeviceType
      new(
        DataType::DeviceTypeId.new(BASIC_VIDEO_PLAYER),
        "Basic Video Player",
        2_u16,
        required_server_clusters: [
          Cluster::Descriptor::CLUSTER_ID,
          Cluster::OnOff::CLUSTER_ID,
          Cluster::MediaPlayback::CLUSTER_ID,
          Cluster::KeypadInput::CLUSTER_ID,
        ],
        optional_server_clusters: [
          Cluster::Messages::CLUSTER_ID,
          Cluster::WakeOnLan::CLUSTER_ID,
          Cluster::Channel::CLUSTER_ID,
          Cluster::TargetNavigator::CLUSTER_ID,
          Cluster::MediaInput::CLUSTER_ID,
          Cluster::LowPower::CLUSTER_ID,
          Cluster::AudioOutput::CLUSTER_ID,
          Cluster::ContentControl::CLUSTER_ID,
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
      when ROOT_NODE                      then root_node
      when POWER_SOURCE                   then power_source
      when JOINT_FABRIC_ADMINISTRATOR     then joint_fabric_administrator
      when BRIDGED_NODE                   then bridged_node
      when SMOKE_CO_ALARM                 then smoke_co_alarm
      when ON_OFF_LIGHT                   then on_off_light
      when DIMMABLE_LIGHT                 then dimmable_light
      when ON_OFF_PLUG_IN_UNIT            then on_off_plug_in_unit
      when ON_OFF_LIGHT_SWITCH            then on_off_light_switch
      when DIMMER_SWITCH                  then dimmer_switch
      when CONTACT_SENSOR                 then contact_sensor
      when TEMPERATURE_SENSOR             then temperature_sensor
      when AIR_QUALITY_SENSOR             then air_quality_sensor
      when SOIL_SENSOR                    then soil_sensor
      when ELECTRICAL_UTILITY_METER       then electrical_utility_meter
      when MICROWAVE_OVEN                 then microwave_oven
      when REFRIGERATOR                   then refrigerator
      when TEMPERATURE_CONTROLLED_CABINET then temperature_controlled_cabinet
      when DISHWASHER                     then dishwasher
      when ROBOTIC_VACUUM_CLEANER         then robotic_vacuum_cleaner
      when DOOR_LOCK                      then door_lock
      when CLOSURE                        then closure
      when CLOSURE_PANEL                  then closure_panel
      when THERMOSTAT                     then thermostat
      when FAN                            then fan
      when BASIC_VIDEO_PLAYER             then basic_video_player
      when CAMERA                         then camera
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
      when ROOT_NODE                      then "Root Node"
      when JOINT_FABRIC_ADMINISTRATOR     then "Joint Fabric Administrator"
      when POWER_SOURCE                   then "Power Source"
      when SMOKE_CO_ALARM                 then "Smoke CO Alarm"
      when OTA_REQUESTOR                  then "OTA Requestor"
      when OTA_PROVIDER                   then "OTA Provider"
      when AGGREGATOR                     then "Aggregator"
      when BRIDGED_NODE                   then "Bridged Node"
      when ON_OFF_LIGHT                   then "On/Off Light"
      when DIMMABLE_LIGHT                 then "Dimmable Light"
      when COLOR_TEMPERATURE_LIGHT        then "Color Temperature Light"
      when EXTENDED_COLOR_LIGHT           then "Extended Color Light"
      when ON_OFF_PLUG_IN_UNIT            then "On/Off Plug-in Unit"
      when DIMMABLE_PLUG_IN_UNIT          then "Dimmable Plug-in Unit"
      when ON_OFF_LIGHT_SWITCH            then "On/Off Light Switch"
      when DIMMER_SWITCH                  then "Dimmer Switch"
      when COLOR_DIMMER_SWITCH            then "Color Dimmer Switch"
      when CONTROL_BRIDGE                 then "Control Bridge"
      when PUMP_CONTROLLER                then "Pump Controller"
      when PUMP                           then "Pump"
      when CONTACT_SENSOR                 then "Contact Sensor"
      when LIGHT_SENSOR                   then "Light Sensor"
      when OCCUPANCY_SENSOR               then "Occupancy Sensor"
      when TEMPERATURE_SENSOR             then "Temperature Sensor"
      when PRESSURE_SENSOR                then "Pressure Sensor"
      when FLOW_SENSOR                    then "Flow Sensor"
      when HUMIDITY_SENSOR                then "Humidity Sensor"
      when AIR_QUALITY_SENSOR             then "Air Quality Sensor"
      when SOIL_SENSOR                    then "Soil Sensor"
      when ELECTRICAL_UTILITY_METER       then "Electrical Utility Meter"
      when MICROWAVE_OVEN                 then "Microwave Oven"
      when REFRIGERATOR                   then "Refrigerator"
      when TEMPERATURE_CONTROLLED_CABINET then "Temperature Controlled Cabinet"
      when DISHWASHER                     then "Dishwasher"
      when ROBOTIC_VACUUM_CLEANER         then "Robotic Vacuum Cleaner"
      when DOOR_LOCK                      then "Door Lock"
      when CLOSURE                        then "Closure"
      when CLOSURE_PANEL                  then "Closure Panel"
      when DOOR_LOCK_CONTROLLER           then "Door Lock Controller"
      when WINDOW_COVERING                then "Window Covering"
      when WINDOW_COVERING_CONTROLLER     then "Window Covering Controller"
      when HEATING_COOLING_UNIT           then "Heating/Cooling Unit"
      when THERMOSTAT                     then "Thermostat"
      when FAN                            then "Fan"
      when BASIC_VIDEO_PLAYER             then "Basic Video Player"
      when CAMERA                         then "Camera"
      when CASTING_VIDEO_PLAYER           then "Casting Video Player"
      when SPEAKER                        then "Speaker"
      when CONTENT_APP                    then "Content App"
      when CASTING_VIDEO_CLIENT           then "Casting Video Client"
      when VIDEO_REMOTE_CONTROL           then "Video Remote Control"
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
