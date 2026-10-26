require "../spec_helper"
require "../../src/matter/cluster/access_control"
require "../../src/matter/cluster/thermostat"
require "../../src/matter/protocol/im_handler"

private alias SetpointThermostat = Matter::Cluster::Thermostat
private alias SetpointACL = Matter::Cluster::AccessControl

describe "Thermostat setpoint write privileges" do
  it "requires Operate for occupied and unoccupied setpoints on a CASE fabric" do
    acl = SetpointACL.new(endpoint(0))
    thermostat = SetpointThermostat.new(endpoint(1),
      feature_map: SetpointThermostat::Feature::Heating |
                   SetpointThermostat::Feature::Cooling |
                   SetpointThermostat::Feature::Occupancy)
    clusters = {
      {0_u16, SetpointACL::CLUSTER_ID}        => acl.as(Matter::Cluster::Base),
      {1_u16, SetpointThermostat::CLUSTER_ID} => thermostat.as(Matter::Cluster::Base),
    }
    subject = 0x1234_u64

    [
      {SetpointThermostat::ATTR_OCCUPIED_COOLING_SETPOINT, 2700_i16},
      {SetpointThermostat::ATTR_OCCUPIED_HEATING_SETPOINT, 2100_i16},
      {SetpointThermostat::ATTR_UNOCCUPIED_COOLING_SETPOINT, 2700_i16},
      {SetpointThermostat::ATTR_UNOCCUPIED_HEATING_SETPOINT, 2100_i16},
    ].each do |attribute_id, value|
      path = Matter::InteractionModel::AttributePath.new(1_u16,
        SetpointThermostat::CLUSTER_ID, attribute_id)
      write = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(value))
      request = Matter::InteractionModel::WriteRequestMessage.new(write_requests: [write])
      parsed = Matter::Protocol::IMHandler.parse_write_request(request.to_slice)
      parsed.should_not be_nil
      writes = parsed.as(Matter::InteractionModel::WriteRequestMessage).write_requests
      previous = read(thermostat, attribute_id)

      [SetpointACL::AccessControlEntryPrivilege::View,
       SetpointACL::AccessControlEntryPrivilege::Operate].each do |privilege|
        acl.acl.clear
        acl.acl << SetpointACL::AccessControlEntry.new(privilege,
          SetpointACL::AccessControlEntryAuthMode::CASE, [subject], nil, 1_u8)
        response = Matter::Protocol::IMHandler.write_attributes(writes, clusters,
          is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [subject]).first
        expected = privilege.view? ? Matter::InteractionModel::StatusCode::UnsupportedAccess : Matter::InteractionModel::StatusCode::Success
        response.status.status.should eq(expected.value)
        read(thermostat, attribute_id).should eq(privilege.view? ? previous : value)
      end
    end
  end
end
