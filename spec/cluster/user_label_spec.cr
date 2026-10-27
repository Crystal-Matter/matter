require "../spec_helper"
require "../../src/matter/cluster/user_label"
require "../../src/matter/cluster/label_struct"

describe Matter::Cluster::UserLabel do
  it "creates a UserLabel cluster with empty label list by default" do
    cluster = build(Matter::Cluster::UserLabel)

    cluster.cluster_id.id.should eq(0x0041_u32)
    cluster.name.should eq("UserLabel")
    cluster.label_list.should be_empty
  end

  it "exposes LabelList as writable attribute" do
    cluster = build(Matter::Cluster::UserLabel)

    meta = cluster.attributes.find { |attr| attr.id.id == Matter::Cluster::UserLabel::ATTR_LABEL_LIST }
    meta.should_not be_nil
    meta = meta.as(Matter::Cluster::AttributeMetadata)
    meta.name.should eq("labelList")
    meta.type.should eq(:array)
    meta.writable?.should be_true
  end

  it "writes LabelList from TLV and updates stored value" do
    cluster = build(Matter::Cluster::UserLabel)

    new_labels = [
      Matter::Cluster::LabelStruct.new("room", "living"),
      Matter::Cluster::LabelStruct.new("control", "volume"),
    ]

    status = write(cluster, Matter::Cluster::UserLabel::ATTR_LABEL_LIST, new_labels)
    status.success?.should be_true

    cluster.label_list.size.should eq(2)
    cluster.label_list[0].label.should eq("room")
    cluster.label_list[0].value.should eq("living")

    list = read_tlv(cluster, Matter::Cluster::UserLabel::ATTR_LABEL_LIST).as_list
    list.size.should eq(2)
  end

  it "rejects invalid LabelList writes" do
    cluster = build(Matter::Cluster::UserLabel)

    status = write(cluster, Matter::Cluster::UserLabel::ATTR_LABEL_LIST, 123_u8)
    status.status.should eq(Matter::InteractionModel::StatusCode::InvalidDataType)
  end

  it "rejects LabelList entries longer than 16 bytes with ConstraintError" do
    cluster = build(Matter::Cluster::UserLabel)

    too_long = [Matter::Cluster::LabelStruct.new("room", "a" * (Matter::Cluster::UserLabel::LABEL_MAX_LENGTH + 1))]
    status = write(cluster, Matter::Cluster::UserLabel::ATTR_LABEL_LIST, too_long)
    status.status.should eq(Matter::InteractionModel::StatusCode::ConstraintError)
    cluster.label_list.should be_empty
  end

  it "persists and restores label list state" do
    cluster = build(Matter::Cluster::UserLabel, label_list: [
      Matter::Cluster::LabelStruct.new("a", "b"),
    ])

    cluster.data_version = 3_u32
    document = cluster.save_state.as(Matter::Storage::Document)
    document["label_list"].should eq([Matter::Storage::Document{"label" => "a", "value" => "b"}] of Matter::Storage::Type)
    document["data_version"].should eq(3_i64)

    restored = build(Matter::Cluster::UserLabel)
    restored.restore_state(document)
    restored.data_version.should eq(3_u32)
    restored.label_list.size.should eq(1)
    restored.label_list[0].label.should eq("a")
    restored.label_list[0].value.should eq("b")
  end

  it "rejects an initial label or value beyond the Matter LabelStruct limit" do
    max = Matter::Cluster::UserLabel::LABEL_MAX_LENGTH
    build(Matter::Cluster::UserLabel, label_list: [Matter::Cluster::LabelStruct.new("l" * max, "v" * max)])
    expect_raises(ArgumentError) do
      build(Matter::Cluster::UserLabel, label_list: [Matter::Cluster::LabelStruct.new("l" * (max + 1), "v")])
    end
    expect_raises(ArgumentError) do
      build(Matter::Cluster::UserLabel, label_list: [Matter::Cluster::LabelStruct.new("l", "v" * (max + 1))])
    end
  end

  it "does not report a LabelList mutated beyond the field limit" do
    cluster = build(Matter::Cluster::UserLabel)
    cluster.label_list << Matter::Cluster::LabelStruct.new("l", "v" * (Matter::Cluster::LabelStruct::MAX_LENGTH + 1))

    read_status(cluster, Matter::Cluster::UserLabel::ATTR_LABEL_LIST).status
      .should eq(Matter::InteractionModel::StatusCode::Failure)

    cluster.label_list[0] = Matter::Cluster::LabelStruct.new("l" * (Matter::Cluster::LabelStruct::MAX_LENGTH + 1), "v")
    read_status(cluster, Matter::Cluster::UserLabel::ATTR_LABEL_LIST).status
      .should eq(Matter::InteractionModel::StatusCode::Failure)

    cluster.label_list[0] = Matter::Cluster::LabelStruct.new("l", "v")
    read_tlv(cluster, Matter::Cluster::UserLabel::ATTR_LABEL_LIST).as_list.size.should eq(1)
  end
end
