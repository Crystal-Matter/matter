require "../spec_helper"
require "../../src/matter/protocol/im_handler"
require "../../src/matter/cluster/identify"
require "../../src/matter/cluster/door_lock"
require "../../src/matter/cluster/bridged_device_basic_information"
require "../../src/matter/cluster/basic_information"
require "../../src/matter/cluster/on_off"
require "../../src/matter/cluster/level_control"
require "../../src/matter/cluster/thermostat"
require "../../src/matter/cluster/occupancy_sensing"
require "../../src/matter/interaction_model/tlv_messages"
require "../../src/matter/cluster/fan_control"

# Decodes a writable enum attribute straight through `Base#decode`, so a type
# mismatch is raised from inside the TLV shard rather than pre-screened by a
# width helper.
private class EnumWriteCluster < Matter::Cluster::Base
  CLUSTER_ID = 0xFFF1_FC01_u32 # manufacturer-specific test cluster
  ATTR_MODE  =      0x0000_u32

  getter mode : Matter::Cluster::FanControl::FanMode = Matter::Cluster::FanControl::FanMode::Off

  def initialize(endpoint_id : Matter::DataType::EndpointNumber)
    super(endpoint_id, Matter::DataType::ClusterId.new(CLUSTER_ID))
  end

  def name : String
    "EnumWrite"
  end

  def attributes : Array(Matter::Cluster::AttributeMetadata)
    [Matter::Cluster::AttributeMetadata.new(id: Matter::DataType::AttributeId.new(ATTR_MODE), name: "mode", type: :enum8, writable: true)]
  end

  protected def handle_write_attribute(attribute_id : UInt32, value : TLV::Any) : Matter::InteractionModel::Status
    return super unless attribute_id == ATTR_MODE
    @mode = decode(value, Matter::Cluster::FanControl::FanMode)
    Matter::InteractionModel::Status.success
  end
end

# Width and type preservation for attribute writes from the official chip-tool.
private def write_via_im(cluster : Matter::Cluster::Base, attribute_id : UInt32, data : TLV::Any) : Matter::InteractionModel::AttributeStatusIB
  endpoint = cluster.endpoint_id.number
  cluster_id = cluster.cluster_id.id
  clusters = {
    {endpoint, cluster_id} => cluster,
  }

  # Serialize and re-parse so the request takes exactly the same path as a
  # message arriving from the network.
  original_msg = Matter::InteractionModel::WriteRequestMessage.new(
    suppress_response: false,
    timed_request: false,
    write_requests: [
      Matter::InteractionModel::AttributeDataIB.new(
        path: Matter::InteractionModel::AttributePath.new(
          endpoint: endpoint,
          cluster: cluster_id,
          attribute: attribute_id,
        ),
        data: data,
      ),
    ],
  )
  parsed = Matter::Protocol::IMHandler.parse_write_request(original_msg.to_slice)
  parsed.should_not be_nil
  parsed = parsed.as(Matter::InteractionModel::WriteRequestMessage)

  results = Matter::Protocol::IMHandler.write_attributes(parsed.write_requests, clusters)
  results.size.should eq 1
  results[0]
end

describe "write_attribute with typed TLV values (chip-tool)" do
  endpoint = endpoint(1)
  success = Matter::InteractionModel::StatusCode::Success.value

  it "writes Identify IdentifyTime (uint16) sent as a single TLV byte" do
    identify = Matter::Cluster::Identify.new(endpoint)

    # chip-tool identify write identify-time 60 1 1
    result = write_via_im(identify, Matter::Cluster::Identify::ATTR_IDENTIFY_TIME, TLV::Any.new(60_u16))
    result.status.status.should eq success
    identify.identify_time.should eq 60_u16
  end

  it "writes Identify IdentifyTime (uint16) sent as two TLV bytes" do
    identify = Matter::Cluster::Identify.new(endpoint)

    result = write_via_im(identify, Matter::Cluster::Identify::ATTR_IDENTIFY_TIME, TLV::Any.new(1000_u16))
    result.status.status.should eq success
    identify.identify_time.should eq 1000_u16
  end

  it "writes DoorLock AutoRelockTime (uint32) sent as a single TLV byte" do
    lock = Matter::Cluster::DoorLock.new(endpoint)

    # chip-tool doorlock write auto-relock-time 30 1 1 --timedInteractionTimeoutMs 2000
    result = write_via_im(lock, Matter::Cluster::DoorLock::ATTR_AUTO_RELOCK_TIME, TLV::Any.new(30_u32))
    result.status.status.should eq success
    lock.auto_relock_time.should eq 30_u32
  end

  it "writes DoorLock Language (string), SoundVolume (enum) and EnableOneTouchLocking (bool)" do
    lock = Matter::Cluster::DoorLock.new(endpoint)

    result = write_via_im(lock, Matter::Cluster::DoorLock::ATTR_LANGUAGE, TLV::Any.new("fr"))
    result.status.status.should eq success
    lock.language.should eq "fr"

    result = write_via_im(lock, Matter::Cluster::DoorLock::ATTR_SOUND_VOLUME, TLV::Any.new(3_u8))
    result.status.status.should eq success
    lock.sound_volume.should eq Matter::Cluster::DoorLock::SoundVolume::Medium

    result = write_via_im(lock, Matter::Cluster::DoorLock::ATTR_SOUND_VOLUME, TLV::Any.new(2_u8))
    result.status.status.should eq success
    lock.sound_volume.should eq Matter::Cluster::DoorLock::SoundVolume::High

    result = write_via_im(lock, Matter::Cluster::DoorLock::ATTR_ENABLE_ONE_TOUCH_LOCKING, TLV::Any.new(true))
    result.status.status.should eq success
    lock.enable_one_touch_locking?.should be_true
  end

  it "writes BridgedDeviceBasicInformation NodeLabel (string)" do
    bridged = Matter::Cluster::BridgedDeviceBasicInformation.new(endpoint, node_label: "Original", unique_id: "test-bridged")

    # chip-tool bridgeddevicebasicinformation write node-label "Porch Light" 1 1
    result = write_via_im(bridged, Matter::Cluster::BridgedDeviceBasicInformation::ATTR_NODE_LABEL, TLV::Any.new("Porch Light"))
    result.status.status.should eq success
    bridged.node_label.should eq "Porch Light"
  end

  it "writes BasicInformation NodeLabel, Location (string) and LocalConfigDisabled (bool)" do
    basic = build(Matter::Cluster::BasicInformation, 0)

    result = write_via_im(basic, Matter::Cluster::BasicInformation::ATTR_NODE_LABEL, TLV::Any.new("Kitchen"))
    result.status.status.should eq success
    basic.node_label.should eq "Kitchen"

    result = write_via_im(basic, Matter::Cluster::BasicInformation::ATTR_LOCATION, TLV::Any.new("au"))
    result.status.status.should eq success
    basic.location.should eq "AU"

    result = write_via_im(basic, Matter::Cluster::BasicInformation::ATTR_LOCAL_CONFIG_DISABLED, TLV::Any.new(true))
    result.status.status.should eq success
    basic.local_config_disabled?.should be_true
  end

  it "writes OnOff OnTime (uint16) sent as a single TLV byte" do
    on_off = Matter::Cluster::OnOff.new(endpoint, feature_map: Matter::Cluster::OnOff::Feature::Lighting)

    # chip-tool onoff write on-time 5 1 1
    result = write_via_im(on_off, Matter::Cluster::OnOff::ATTR_ON_TIME, TLV::Any.new(5_u16))
    result.status.status.should eq success
    on_off.on_time.should eq 5_u16

    result = write_via_im(on_off, Matter::Cluster::OnOff::ATTR_OFF_WAIT_TIME, TLV::Any.new(7_u16))
    result.status.status.should eq success
    on_off.off_wait_time.should eq 7_u16
  end

  it "writes OnOff StartUpOnOff null sent as TLV null" do
    on_off = Matter::Cluster::OnOff.new(endpoint, feature_map: Matter::Cluster::OnOff::Feature::Lighting)

    result = write_via_im(on_off, Matter::Cluster::OnOff::ATTR_START_UP_ON_OFF, TLV::Any.new(1_u8))
    result.status.status.should eq success
    on_off.start_up_on_off.should eq Matter::Cluster::OnOff::StartUpOnOff::On

    result = write_via_im(on_off, Matter::Cluster::OnOff::ATTR_START_UP_ON_OFF, TLV::Any.new(nil))
    result.status.status.should eq success
    on_off.start_up_on_off.should be_nil
  end

  it "writes LevelControl OnOffTransitionTime (uint16) sent as a single TLV byte" do
    level = Matter::Cluster::LevelControl.new(endpoint, feature_map: Matter::Cluster::LevelControl::Feature::Lighting | Matter::Cluster::LevelControl::Feature::OnOff)

    result = write_via_im(level, Matter::Cluster::LevelControl::ATTR_ON_OFF_TRANSITION_TIME, TLV::Any.new(5_u16))
    result.status.status.should eq success
    level.on_off_transition_time.should eq 5_u16
  end

  it "writes Thermostat OccupiedHeatingSetpoint (int16) sent as a single TLV byte" do
    # Lower the heating limits so a setpoint small enough to fit in an int8
    # on the wire (1.00 degrees C) is within range.
    thermostat = Matter::Cluster::Thermostat.new(
      endpoint,
      feature_map: Matter::Cluster::Thermostat::Feature::Heating,
      abs_min_heat_setpoint_limit: 0_i16,
      min_heat_setpoint_limit: 0_i16,
    )

    result = write_via_im(thermostat, Matter::Cluster::Thermostat::ATTR_OCCUPIED_HEATING_SETPOINT, TLV::Any.new(100_i16))
    result.status.status.should eq success
    thermostat.occupied_heating_setpoint.should eq 100_i16
  end

  it "writes OccupancySensing PIROccupiedToUnoccupiedDelay (uint16) sent as a single TLV byte" do
    occupancy = Matter::Cluster::OccupancySensing.new(endpoint, feature_map: Matter::Cluster::OccupancySensing::Feature::PassiveInfrared, hold_time: 60_u16)

    # chip-tool occupancysensing write piroccupied-to-unoccupied-delay 10 1 1
    result = write_via_im(occupancy, Matter::Cluster::OccupancySensing::ATTR_PIR_OCCUPIED_TO_UNOCCUPIED_DELAY, TLV::Any.new(10_u16))
    result.status.status.should eq success
    occupancy.pir_occupied_to_unoccupied_delay.should eq 10_u16

    result = write_via_im(occupancy, Matter::Cluster::OccupancySensing::ATTR_HOLD_TIME, TLV::Any.new(300_u16))
    result.status.status.should eq success
    occupancy.hold_time.should eq 300_u16
  end

  it "rejects a non-integer value with InvalidDataType" do
    identify = Matter::Cluster::Identify.new(endpoint)

    result = write_via_im(identify, Matter::Cluster::Identify::ATTR_IDENTIFY_TIME, TLV::Any.new("sixty"))
    result.status.status.should eq Matter::InteractionModel::StatusCode::InvalidDataType.value
    identify.identify_time.should eq 0_u16
  end
end

describe "FanControl writes through the interaction model" do
  it "writes UInt8 attribute via round-tripped TLV bytes (simulating iOS wire format)" do
    endpoint = endpoint(1)
    fan = Matter::Cluster::FanControl.new(
      endpoint,
      fan_mode: Matter::Cluster::FanControl::FanMode::Off,
      fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowMedHigh,
      percent_setting: 0_u8,
      percent_current: 0_u8,
      speed_max: 4_u8,
    )

    clusters = {
      {1_u16, 0x0202_u32} => fan.as(Matter::Cluster::Base),
    }

    # Build a WriteRequestMessage, serialize to TLV, then parse it back —
    # this is exactly what happens on the wire from iOS Home
    original_msg = Matter::InteractionModel::WriteRequestMessage.new(
      suppress_response: false,
      timed_request: false,
      write_requests: [
        Matter::InteractionModel::AttributeDataIB.new(
          path: Matter::InteractionModel::AttributePath.new(
            endpoint: 1_u16,
            cluster: 0x0202_u32,
            attribute: 0x0002_u32,
          ),
          data: TLV::Any.new(100_u8),
        ),
      ],
    )

    # Serialize and re-parse (simulates network round-trip)
    wire_bytes = original_msg.to_slice
    parsed_msg = Matter::Protocol::IMHandler.parse_write_request(wire_bytes)
    parsed_msg.should_not be_nil
    parsed_msg = parsed_msg.as(Matter::InteractionModel::WriteRequestMessage)

    # Now write through the full path
    results = Matter::Protocol::IMHandler.write_attributes(parsed_msg.write_requests, clusters)
    results.size.should eq 1
    results[0].status.status.should eq 0_u8 # Success — NOT 0x8d (InvalidDataType)

    fan.percent_setting.should eq 100_u8
  end

  it "writes FanMode enum via TLV round-trip" do
    endpoint = endpoint(1)
    fan = Matter::Cluster::FanControl.new(
      endpoint,
      fan_mode: Matter::Cluster::FanControl::FanMode::Off,
      fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowMedHigh,
      percent_setting: 0_u8,
      percent_current: 0_u8,
      speed_max: 4_u8,
    )

    clusters = {
      {1_u16, 0x0202_u32} => fan.as(Matter::Cluster::Base),
    }

    # Write FanMode (attribute 0x00) = 3 (High)
    original_msg = Matter::InteractionModel::WriteRequestMessage.new(
      suppress_response: false,
      timed_request: false,
      write_requests: [
        Matter::InteractionModel::AttributeDataIB.new(
          path: Matter::InteractionModel::AttributePath.new(
            endpoint: 1_u16,
            cluster: 0x0202_u32,
            attribute: 0x0000_u32, # FanMode
          ),
          data: TLV::Any.new(3_u8), # High
        ),
      ],
    )

    wire_bytes = original_msg.to_slice
    parsed_msg = Matter::Protocol::IMHandler.parse_write_request(wire_bytes).as(Matter::InteractionModel::WriteRequestMessage)

    results = Matter::Protocol::IMHandler.write_attributes(parsed_msg.write_requests, clusters)
    results.size.should eq 1
    results[0].status.status.should eq 0_u8

    fan.fan_mode.should eq Matter::Cluster::FanControl::FanMode::High
  end
end

describe "TLV attribute type preservation" do
  it "distinguishes the unsigned value 20 from null" do
    cluster = build(Matter::Cluster::OnOff, feature_map: Matter::Cluster::OnOff::Feature::Lighting)
    attribute = Matter::Cluster::OnOff::ATTR_START_UP_ON_OFF

    expect_success(write(cluster, attribute, 1_u8))
    expect_status(write(cluster, attribute, 20_u8), Matter::InteractionModel::StatusCode::ConstraintError)
    read_tlv(cluster, attribute).as_u8.should eq(1_u8)
    expect_success(write(cluster, attribute, nil))
    read_tlv(cluster, attribute).value.should be_nil
  end

  it "accepts a wider unsigned encoding without truncating overflow" do
    cluster = build(Matter::Cluster::Identify)
    attribute = Matter::Cluster::Identify::ATTR_IDENTIFY_TIME

    expect_success(write(cluster, attribute, TLV::Any.new(300_u64, fixed_size: true)))
    cluster.identify_time.should eq(300_u16)
    expect_status(write(cluster, attribute, TLV::Any.new(UInt16::MAX.to_u64 + 1)), Matter::InteractionModel::StatusCode::InvalidDataType)
    cluster.identify_time.should eq(300_u16)
  end

  it "keeps signed values distinct from unsigned values" do
    fan = build(Matter::Cluster::FanControl)
    expect_status(write(fan, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, -1_i8), Matter::InteractionModel::StatusCode::InvalidDataType)
    expect_status(write(fan, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, true), Matter::InteractionModel::StatusCode::InvalidDataType)

    thermostat = build(Matter::Cluster::Thermostat)
    expect_success(write(thermostat, Matter::Cluster::Thermostat::ATTR_OCCUPIED_HEATING_SETPOINT, 2100_u16))
    thermostat.occupied_heating_setpoint.should eq(2100_i16)
  end

  # Documents the intentional strictness of `narrow_u8?`: an unsigned attribute
  # only accepts unsigned TLV encodings, so a positive value sent as a signed
  # integer is still the wrong data type even though it would fit.
  it "rejects a signed encoding of a positive value for an unsigned attribute" do
    fan = build(Matter::Cluster::FanControl)
    original = fan.percent_setting

    expect_status(write(fan, Matter::Cluster::FanControl::ATTR_PERCENT_SETTING, 100_i8), Matter::InteractionModel::StatusCode::InvalidDataType)
    fan.percent_setting.should eq(original)
  end
end

describe "UTF-8 attribute writes" do
  it "rejects malformed UTF-8 from a real WriteRequest without changing state" do
    cluster = build(Matter::Cluster::BasicInformation, 0)
    original_label = cluster.node_label
    original_version = cluster.data_version
    # A two-byte UTF-8 lead byte followed by an ASCII byte is invalid.
    invalid_label = String.new(Bytes[0xC3, 0x28])
    invalid_label.valid_encoding?.should be_false

    status = write_via_im(cluster, Matter::Cluster::BasicInformation::ATTR_NODE_LABEL, TLV::Any.new(invalid_label))
    status.status.status.should eq(Matter::InteractionModel::StatusCode::InvalidDataType.value)
    cluster.node_label.should eq(original_label)
    cluster.data_version.should eq(original_version)
  end

  it "a mistyped enum write yields InvalidDataType" do
    fan = build(Matter::Cluster::FanControl)
    expect_status(write(fan, Matter::Cluster::FanControl::ATTR_FAN_MODE, "auto"), Matter::InteractionModel::StatusCode::InvalidDataType)
    fan.fan_mode.should eq(Matter::Cluster::FanControl::FanMode::Off)

    cluster = build(EnumWriteCluster)
    expect_status(write(cluster, EnumWriteCluster::ATTR_MODE, "auto"), Matter::InteractionModel::StatusCode::InvalidDataType)
    cluster.mode.should eq(Matter::Cluster::FanControl::FanMode::Off)
  end
end
