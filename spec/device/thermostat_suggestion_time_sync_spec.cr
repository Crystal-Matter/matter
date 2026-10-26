require "../spec_helper"
require "../../src/matter/device"
require "../../src/matter/cluster/thermostat"
require "../../src/matter/cluster/time_synchronization"
require "../../src/matter/cluster/identify"
require "../../src/matter/cluster/groups"

private alias SuggestionTimeSync = Matter::Cluster::TimeSynchronization

private class TimeSyncSuggestionThermostat < Matter::Cluster::Thermostat
  protected def preset_wire_ready? : Bool
    true
  end

  protected def suggestion_wire_ready? : Bool
    true
  end

  protected def suggestion_wire_ready?(command_id : UInt32) : Bool
    true
  end
end

private class TimeSyncSuggestionDevice < Matter::Device
  @thermostat : TimeSyncSuggestionThermostat? = nil

  def initialize
    super(Matter::Storage::Memory.new, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
  end

  def device_name : String
    "Suggestion UTC Test"
  end

  def vendor_id : UInt16
    0xFFF1_u16
  end

  def product_id : UInt16
    0x8132_u16
  end

  def discriminator : UInt16
    3850_u16
  end

  def setup_pin : UInt32
    20202099_u32
  end

  def primary_device_type_id : UInt32
    Matter::DeviceType::THERMOSTAT
  end

  def thermostat : TimeSyncSuggestionThermostat
    @thermostat.as(TimeSyncSuggestionThermostat)
  end

  def time_sync : SuggestionTimeSync
    node.get_cluster!(0_u16, SuggestionTimeSync)
  end

  protected def device_clusters : Array(Matter::Cluster::Base)
    endpoint_number = endpoint(1_u16)
    @thermostat = TimeSyncSuggestionThermostat.new(endpoint_number,
      feature_map: TimeSyncSuggestionThermostat::Feature::Heating |
                   TimeSyncSuggestionThermostat::Feature::Presets |
                   TimeSyncSuggestionThermostat::Feature::ThermostatSuggestions,
      preset_types: [TimeSyncSuggestionThermostat::PresetType.new(TimeSyncSuggestionThermostat::PresetScenario::Sleep, 1_u8)],
      presets: [TimeSyncSuggestionThermostat::Preset.new(Bytes[1_u8], TimeSyncSuggestionThermostat::PresetScenario::Sleep,
        nil, nil, 1900_i16, false)])
    [SuggestionTimeSync.new, thermostat,
     Matter::Cluster::Identify.new(endpoint_number),
     Matter::Cluster::Groups.new(endpoint_number)] of Matter::Cluster::Base
  end

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {1_u16 => Matter::DeviceType::THERMOSTAT}
  end
end

describe "Thermostat suggestion root UTC integration" do
  it "rejects unsynchronized Add, follows and expires from root UTC without reads, and rejects after time failure" do
    require_udp_sockets!
    device = TimeSyncSuggestionDevice.new
    thermostat = device.thermostat
    time_sync = device.time_sync
    request = TimeSyncSuggestionThermostat::AddThermostatSuggestionRequest.new(Bytes[1_u8], 1_030_u32, 30_u16)

    thermostat.invoke_command(TimeSyncSuggestionThermostat::CMD_ADD_THERMOSTAT_SUGGESTION,
      request.to_tlv(nil), is_case_session: true).as(Matter::InteractionModel::Status).status.should eq(
      Matter::InteractionModel::StatusCode::InvalidInState)
    time_sync.apply_utc_time(SuggestionTimeSync::SetUtcTimeRequest.new(1_000_000_000_u64,
      SuggestionTimeSync::Granularity::Seconds)).status.should eq(Matter::InteractionModel::StatusCode::Success)
    added = thermostat.invoke_command(TimeSyncSuggestionThermostat::CMD_ADD_THERMOSTAT_SUGGESTION,
      request.to_tlv(nil), is_case_session: true)
    added.should be_a(Matter::Cluster::CommandResponse)
    thermostat.active_preset_handle.should be_nil

    changed = [] of UInt32
    thermostat.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, id : UInt32) : Nil {
      changed << id
      nil
    }
    device.start
    time_sync.apply_utc_time(SuggestionTimeSync::SetUtcTimeRequest.new(1_031_000_000_u64,
      SuggestionTimeSync::Granularity::Seconds))
    deadline = Time.instant + 3.seconds
    until thermostat.active_preset_handle == Bytes[1_u8] || Time.instant >= deadline
      sleep 25.milliseconds
    end
    thermostat.active_preset_handle.should eq(Bytes[1_u8])
    changed.should contain(TimeSyncSuggestionThermostat::ATTR_CURRENT_THERMOSTAT_SUGGESTION)

    changed.clear
    time_sync.apply_utc_time(SuggestionTimeSync::SetUtcTimeRequest.new(2_831_000_000_u64,
      SuggestionTimeSync::Granularity::Seconds))
    deadline = Time.instant + 3.seconds
    until changed.includes?(TimeSyncSuggestionThermostat::ATTR_THERMOSTAT_SUGGESTIONS) || Time.instant >= deadline
      sleep 25.milliseconds
    end
    changed.should contain(TimeSyncSuggestionThermostat::ATTR_THERMOSTAT_SUGGESTIONS)
    time_sync.report_time_failure
    thermostat.invoke_command(TimeSyncSuggestionThermostat::CMD_ADD_THERMOSTAT_SUGGESTION,
      request.to_tlv(nil), is_case_session: true).as(Matter::InteractionModel::Status).status.should eq(
      Matter::InteractionModel::StatusCode::InvalidInState)
  ensure
    device.try(&.shutdown!)
  end
end
