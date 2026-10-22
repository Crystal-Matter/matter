require "../spec_helper"

require "../../src/matter/cluster/basic_information"

describe Matter::Cluster::BasicInformation do
  it "persists writable attributes (node_label/location/local_config_disabled)" do
    ep0 = endpoint(0)
    cluster = Matter::Cluster::BasicInformation.new(
      endpoint_id: ep0,
      vendor_name: "Vendor",
      vendor_id: 0xFFF1_u16,
      product_name: "Prod",
      product_id: 0x8004_u16,
      node_label: "Initial",
      location: "XX"
    )

    cluster.node_label = "Kitchen"
    cluster.location = "AU"
    cluster.local_config_disabled = true
    cluster.configuration_version = 3_u32
    cluster.data_version = 42_u32

    document = cluster.save_state.as(Matter::Storage::Document)
    document.should eq(Matter::Storage::Document{
      "node_label"            => "Kitchen",
      "location"              => "AU",
      "local_config_disabled" => true,
      "configuration_version" => 3_i64,
      "data_version"          => 42_i64,
      "features"              => 0_i64,
    })

    cluster2 = Matter::Cluster::BasicInformation.new(
      endpoint_id: ep0,
      vendor_name: "Vendor",
      vendor_id: 0xFFF1_u16,
      product_name: "Prod",
      product_id: 0x8004_u16,
      node_label: "Other",
      location: "XX"
    )
    cluster2.restore_state(document)

    cluster2.node_label.should eq("Kitchen")
    cluster2.location.should eq("AU")
    cluster2.local_config_disabled?.should be_true
    cluster2.configuration_version.should eq(3_u32)
    cluster2.data_version.should eq(42_u32)
  end

  it "restores older documents that predate ConfigurationVersion" do
    cluster = Matter::Cluster::BasicInformation.new(endpoint(0), product_name: "Old product")
    cluster.restore_state(Matter::Storage::Document{
      "node_label"            => "Persisted name",
      "location"              => "AU",
      "local_config_disabled" => false,
      "data_version"          => 7_i64,
    })

    cluster.node_label.should eq("Persisted name")
    cluster.location.should eq("AU")
    cluster.configuration_version.should eq(Matter::Cluster::BasicInformation::INITIAL_CONFIGURATION_VERSION)
    cluster.data_version.should eq(7_u32)
    cluster.save_state.as(Matter::Storage::Document)["configuration_version"].should eq(1_i64)
  end

  it "persists an advanced ConfigurationVersion across restart" do
    source = Matter::Cluster::BasicInformation.new(endpoint(0), product_name: "Bridge")
    source.increase_configuration_version { source.node_label = "Updated" }

    restored = Matter::Cluster::BasicInformation.new(endpoint(0), product_name: "Bridge")
    restored.restore_state(source.save_state.as(Matter::Storage::Document))

    restored.configuration_version.should eq(2_u32)
    restored.node_label.should eq("Updated")
  end

  it "repairs an invalid persisted zero ConfigurationVersion before advertising it" do
    source = Matter::Cluster::BasicInformation.new(endpoint(0), product_name: "Bridge")
    document = source.save_state.as(Matter::Storage::Document)
    document["configuration_version"] = 0_i64

    restored = Matter::Cluster::BasicInformation.new(endpoint(0), product_name: "Bridge")
    restored.restore_state(document)

    restored.configuration_version.should eq(Matter::Cluster::BasicInformation::INITIAL_CONFIGURATION_VERSION)
    restored.save_state.as(Matter::Storage::Document)["configuration_version"].should eq(1_i64)
  end
end
