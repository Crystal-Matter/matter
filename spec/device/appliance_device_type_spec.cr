require "../spec_helper"
require "../../src/matter/device"

private alias ApplianceType = Matter::DeviceType
private alias ApplianceCluster = Matter::Cluster

private class RefrigeratorCompositionDevice < Matter::Device
  identity vendor: "Crystal", product: "Refrigerator composition test",
    vendor_id: 0xFFF1_u16, product_id: 0x9270_u16,
    discriminator: 3840_u16, pin: 20202021_u32,
    device_type: ApplianceType::REFRIGERATOR
  storage :memory

  endpoint 1, device_type: [ApplianceType::REFRIGERATOR,
                            ApplianceType::TEMPERATURE_CONTROLLED_CABINET] do
    cluster ApplianceCluster::TemperatureControl,
      feature_map: ApplianceCluster::TemperatureControl::Feature::TemperatureNumber
  end
end

describe "Matter 1.6 appliance device types" do
  it "maps canonical Refrigerator, Cabinet and Dishwasher IDs and revisions" do
    ApplianceType.for(ApplianceType::REFRIGERATOR).revision.should eq(3_u16)
    ApplianceType.for(ApplianceType::TEMPERATURE_CONTROLLED_CABINET).revision.should eq(6_u16)
    ApplianceType.for(ApplianceType::DISHWASHER).revision.should eq(2_u16)
    ApplianceType.name(ApplianceType::REFRIGERATOR).should eq("Refrigerator")
    ApplianceType.name(ApplianceType::DISHWASHER).should eq("Dishwasher")
  end

  it "advertises Refrigerator and its Cooler cabinet on one static endpoint" do
    device = RefrigeratorCompositionDevice.new(port: 0)
    types = device.node.endpoint!(1_u16).descriptor.device_type_list
    types.map(&.device_type).should eq([ApplianceType::REFRIGERATOR,
                                        ApplianceType::TEMPERATURE_CONTROLLED_CABINET])
    types.map(&.revision).should eq([3_u16, 6_u16])
    device.node.validate.should be_empty
  ensure
    device.try(&.transport.close)
  end

  it "requires the Cooler cabinet companion on the Refrigerator endpoint" do
    endpoint = Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16),
      [ApplianceType.refrigerator])
    endpoint.populate_descriptor
    endpoint.validate.join(" ").should contain("Temperature Controlled Cabinet")
  end

  it "requires numeric Temperature Control and rejects level control for a cabinet" do
    endpoint = Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16),
      [ApplianceType.temperature_controlled_cabinet])
    endpoint.add_cluster(ApplianceCluster::TemperatureControl.new(endpoint.endpoint_id,
      feature_map: ApplianceCluster::TemperatureControl::Feature::TemperatureLevel,
      supported_temperature_levels: ["Cold", "Warm"]))
    endpoint.populate_descriptor
    endpoint.validate.join(" ").should contain("required feature")
    endpoint.validate.join(" ").should contain("Forbidden feature")
  end

  it "requires Operational State and OperationCompletion for Dishwasher" do
    endpoint = Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16),
      [ApplianceType.dishwasher])
    endpoint.populate_descriptor
    endpoint.validate.join(" ").should contain("cluster 0x0060")

    state = ApplianceCluster::OperationalState.new(endpoint.endpoint_id)
    endpoint.add_cluster(state)
    endpoint.validate.should be_empty
    state.events.map(&.id.id).should contain(0x01_u32)
  end

  it "requires DeadFrontBehavior only when Dishwasher includes OnOff" do
    endpoint = Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16),
      [ApplianceType.dishwasher])
    endpoint.add_cluster(ApplianceCluster::OperationalState.new(endpoint.endpoint_id))
    endpoint.add_cluster(ApplianceCluster::OnOff.new(endpoint.endpoint_id))
    endpoint.populate_descriptor
    endpoint.validate.join(" ").should contain("required feature 0x00000002")

    on_off = ApplianceCluster::OnOff.new(endpoint.endpoint_id,
      feature_map: ApplianceCluster::OnOff::Feature::DeadFrontBehavior)
    endpoint.add_cluster(on_off)
    endpoint.validate.should be_empty
  end

  it "checks event and forbidden-attribute conditions through device-type metadata" do
    custom = ApplianceType.new(Matter::DataType::DeviceTypeId.new(0xFFF2_u32),
      "Test appliance", 1_u16,
      required_server_events: {0x0060_u32 => [0x0099_u32]},
      forbidden_server_attributes: {0x0060_u32 => [0x0003_u32]})
    endpoint = Matter::Endpoint.new(Matter::DataType::EndpointNumber.new(1_u16), [custom])
    endpoint.add_cluster(ApplianceCluster::OperationalState.new(endpoint.endpoint_id))
    errors = endpoint.validate.join(" ")
    errors.should contain("Missing required event 0x0099")
    errors.should contain("Forbidden attribute 0x0003")
  end
end
