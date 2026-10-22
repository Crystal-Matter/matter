require "../spec_helper"
require "../../src/matter/cluster/application_basic"

private alias ApplicationBasic = Matter::Cluster::ApplicationBasic
private alias IMCode = Matter::InteractionModel::StatusCode

private def application_basic(*, application_name : String = "Crystal Radio",
                              application_version : String = "1.2.3",
                              allowed_vendor_list : Array(UInt16) = [0xFFF1_u16],
                              vendor_name : String? = nil, vendor_id : UInt16? = nil,
                              product_id : UInt16? = nil)
  build(ApplicationBasic,
    application_name: application_name,
    application: ApplicationBasic::Application.new(0xFFF1_u16, "radio.crystal"),
    application_version: application_version,
    allowed_vendor_list: allowed_vendor_list,
    vendor_name: vendor_name, vendor_id: vendor_id, product_id: product_id)
end

describe ApplicationBasic do
  it "exposes revision one mandatory attributes and a tagged ApplicationStruct" do
    cluster = application_basic
    cluster.cluster_id.id.should eq(0x050D_u32)
    cluster.cluster_revision.should eq(1_u16)
    attribute_ids(cluster).first(5).should eq([
      ApplicationBasic::ATTR_APPLICATION_NAME,
      ApplicationBasic::ATTR_APPLICATION,
      ApplicationBasic::ATTR_STATUS,
      ApplicationBasic::ATTR_APPLICATION_VERSION,
      ApplicationBasic::ATTR_ALLOWED_VENDOR_LIST,
    ])
    cluster.commands.should be_empty
    read(cluster, ApplicationBasic::ATTR_APPLICATION_NAME).should eq("Crystal Radio")
    application = ApplicationBasic::Application.from_tlv(read_tlv(cluster, ApplicationBasic::ATTR_APPLICATION))
    application.catalog_vendor_id.should eq(0xFFF1_u16)
    application.application_id.should eq("radio.crystal")
    read(cluster, ApplicationBasic::ATTR_STATUS).should eq(0_u8)
    read(cluster, ApplicationBasic::ATTR_APPLICATION_VERSION).should eq("1.2.3")
    read_tlv(cluster, ApplicationBasic::ATTR_ALLOWED_VENDOR_LIST).as_list.size.should eq(1)
    cluster.get_attribute_metadata(ApplicationBasic::ATTR_ALLOWED_VENDOR_LIST)
      .as(Matter::Cluster::AttributeMetadata).access
      .should eq(Matter::InteractionModel::EntryPrivilege::Administer)
  end

  it "exposes optional fixed identity fields only when configured" do
    cluster = application_basic(vendor_name: "Crystal", vendor_id: 0xFFF1_u16, product_id: 10_u16)
    attribute_ids(cluster).should contain(ApplicationBasic::ATTR_VENDOR_NAME)
    attribute_ids(cluster).should contain(ApplicationBasic::ATTR_VENDOR_ID)
    attribute_ids(cluster).should contain(ApplicationBasic::ATTR_PRODUCT_ID)
    read(cluster, ApplicationBasic::ATTR_VENDOR_NAME).should eq("Crystal")
    read(cluster, ApplicationBasic::ATTR_VENDOR_ID).should eq(0xFFF1_u16)
    read(cluster, ApplicationBasic::ATTR_PRODUCT_ID).should eq(10_u16)
    cluster.attributes.reject { |a| a.id.id == ApplicationBasic::ATTR_STATUS }.all?(&.fixed?).should be_true

    omitted = application_basic
    omitted.get_attribute_metadata(ApplicationBasic::ATTR_VENDOR_NAME).should be_nil
    omitted.get_attribute_metadata(ApplicationBasic::ATTR_VENDOR_ID).should be_nil
    omitted.get_attribute_metadata(ApplicationBasic::ATTR_PRODUCT_ID).should be_nil
  end

  it "validates fixed string lengths and keeps the allowed vendor list isolated" do
    expect_raises(ArgumentError) { application_basic(application_name: "a" * 257) }
    expect_raises(ArgumentError) { application_basic(application_version: "v" * 33) }
    expect_raises(ArgumentError) { application_basic(vendor_name: "v" * 33) }

    vendors = [0xFFF1_u16]
    cluster = application_basic(allowed_vendor_list: vendors)
    vendors << 0xFFF2_u16
    cluster.allowed_vendor_list << 0xFFF3_u16
    cluster.allowed_vendor_list.should eq([0xFFF1_u16])
    read_tlv(cluster, ApplicationBasic::ATTR_ALLOWED_VENDOR_LIST).as_list.size.should eq(1)
  end

  it "updates runtime status and resets it after a host restart" do
    cluster = application_basic
    changes = [] of Tuple(ApplicationBasic::ApplicationStatus, ApplicationBasic::ApplicationStatus)
    cluster.on_status_changed { |old_value, new_value| changes << {old_value, new_value} }
    initial_version = cluster.data_version
    cluster.update_status(ApplicationBasic::ApplicationStatus::ActiveVisibleFocus)
    cluster.data_version.should_not eq(initial_version)
    cluster.update_status(ApplicationBasic::ApplicationStatus::ActiveHidden)
    changes.should eq([
      {ApplicationBasic::ApplicationStatus::Stopped, ApplicationBasic::ApplicationStatus::ActiveVisibleFocus},
      {ApplicationBasic::ApplicationStatus::ActiveVisibleFocus, ApplicationBasic::ApplicationStatus::ActiveHidden},
    ])
    cluster.save_state.should be_nil
    restored = application_basic
    restored.status.should eq(ApplicationBasic::ApplicationStatus::Stopped)
  end

  it "rejects interaction-model writes to every attribute" do
    cluster = application_basic(vendor_name: "Crystal", vendor_id: 0xFFF1_u16, product_id: 10_u16)
    cluster.attributes.each do |metadata|
      write(cluster, metadata.id.id, 0_u8).status.should eq(IMCode::UnsupportedWrite)
    end
  end
end
