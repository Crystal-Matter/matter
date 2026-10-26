require "../spec_helper"
require "../../src/matter/device"
require "../../src/matter/cluster/thermostat"
require "../../src/matter/cluster/identify"
require "../../src/matter/cluster/groups"

private class PollingThermostat < Matter::Cluster::Thermostat
  protected def schedule_wire_ready? : Bool
    true
  end
end

private class PollingThermostatDevice < Matter::Device
  @thermostat : PollingThermostat? = nil

  def initialize(@clock : Proc(Time?), storage : Matter::Storage::Backend = Matter::Storage::Memory.new)
    super(storage, port: 0,
      ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)])
  end

  def thermostat : PollingThermostat
    @thermostat.as(PollingThermostat)
  end

  def device_name : String
    "Schedule Polling Test"
  end

  def vendor_id : UInt16
    0xFFF1_u16
  end

  def product_id : UInt16
    0x8129_u16
  end

  def discriminator : UInt16
    3849_u16
  end

  def setup_pin : UInt32
    20202097_u32
  end

  def primary_device_type_id : UInt32
    Matter::DeviceType::THERMOSTAT
  end

  protected def device_clusters : Array(Matter::Cluster::Base)
    endpoint_number = endpoint(1_u16)
    @thermostat = PollingThermostat.new(endpoint_number,
      feature_map: PollingThermostat::Feature::Heating | PollingThermostat::Feature::MatterSchedules |
                   PollingThermostat::Feature::Events,
      local_time_provider: @clock)
    type = PollingThermostat::ScheduleType.new(PollingThermostat::SystemMode::Heat, 1_u8,
      PollingThermostat::ScheduleTypeFeatures::SupportsSetpoints)
    transition = PollingThermostat::ScheduleTransition.new(0x02_u8, 480_u16,
      nil, nil, nil, 1900_i16)
    schedule = PollingThermostat::Schedule.new(Bytes[1_u8], PollingThermostat::SystemMode::Heat,
      nil, nil, [transition], false)
    thermostat.configure_schedules([type], [schedule], 2_u8, 2_u8)
    [thermostat, Matter::Cluster::Identify.new(endpoint_number),
     Matter::Cluster::Groups.new(endpoint_number)] of Matter::Cluster::Base
  end

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {1_u16 => Matter::DeviceType::THERMOSTAT}
  end
end

describe "Thermostat schedule runtime polling" do
  it "activates when the local clock becomes valid without an IM request" do
    require_udp_sockets!
    now = nil.as(Time?)
    device = PollingThermostatDevice.new(-> : Time? { now })
    thermostat = device.thermostat
    events = [] of UInt32
    thermostat.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, id : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << id
      nil
    end
    thermostat.activate_schedule(PollingThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))
    thermostat.occupied_heating_setpoint.should eq(PollingThermostat::DEFAULT_HEATING_SETPOINT)
    device.start
    now = Time.utc(2026, 10, 26, 8, 0)
    deadline = Time.instant + 3.seconds
    until thermostat.occupied_heating_setpoint == 1900_i16 || Time.instant >= deadline
      sleep 25.milliseconds
    end
    thermostat.occupied_heating_setpoint.should eq(1900_i16)
    events.count(PollingThermostat::EVENT_SETPOINT_CHANGE).should eq(1)
    sleep 1.2.seconds
    events.count(PollingThermostat::EVENT_SETPOINT_CHANGE).should eq(1)
  ensure
    device.try(&.shutdown!)
  end

  it "restores the schedule and keeps polling after a device restart" do
    require_udp_sockets!
    path = File.join(Dir.tempdir, "matter-msch-poll-#{Random::Secure.hex(6)}.yml")
    now = nil.as(Time?)
    first = PollingThermostatDevice.new(-> : Time? { now }, Matter::Storage::YamlFile.new(path))
    first.thermostat.activate_schedule(PollingThermostat::SetActiveScheduleRequest.new(Bytes[1_u8]))
    first.start
    first.shutdown!

    now = Time.utc(2026, 10, 26, 8, 0)
    restored = PollingThermostatDevice.new(-> : Time? { now }, Matter::Storage::YamlFile.new(path))
    restored.start
    deadline = Time.instant + 3.seconds
    until restored.thermostat.occupied_heating_setpoint == 1900_i16 || Time.instant >= deadline
      sleep 25.milliseconds
    end
    restored.thermostat.occupied_heating_setpoint.should eq(1900_i16)
  ensure
    first.try(&.shutdown!)
    restored.try(&.shutdown!)
    File.delete?(path) if path
  end
end
