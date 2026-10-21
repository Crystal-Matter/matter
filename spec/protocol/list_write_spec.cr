require "../spec_helper"

private def user_label_writes
  endpoint = Matter::DataType::EndpointNumber.new(1_u16)
  labels = Matter::Cluster::UserLabel.new(endpoint)
  clusters = {} of Tuple(UInt16, UInt32) => Matter::Cluster::Base
  clusters[{1_u16, Matter::Cluster::UserLabel::CLUSTER_ID}] = labels
  {labels, clusters}
end

private def user_label_data(value : TLV::Any, *, append : Bool = false, index : UInt16? = nil) : Matter::InteractionModel::AttributeDataIB
  path = Matter::InteractionModel::AttributePath.new(
    endpoint: 1_u16,
    cluster: Matter::Cluster::UserLabel::CLUSTER_ID,
    attribute: Matter::Cluster::UserLabel::ATTR_LABEL_LIST,
    list_index: index,
    list_index_null: append
  )
  Matter::InteractionModel::AttributeDataIB.new(path, value)
end

describe "Interaction Model list writes" do
  it "replaces a list, then appends an item marked by a null ListIndex" do
    labels, clusters = user_label_writes
    clear = user_label_data(TLV::Any.from_tlv(([] of Matter::Cluster::LabelStruct).to_tlv))
    append = user_label_data(Matter::Cluster::LabelStruct.new("room", "office").to_tlv, append: true)

    statuses = Matter::Protocol::IMHandler.write_attributes([clear, append], clusters)

    statuses.map(&.status.status).should eq([Matter::InteractionModel::StatusCode::Success.value] * 2)
    labels.label_list.should eq([Matter::Cluster::LabelStruct.new("room", "office")])
  end

  it "rejects an append without the preceding list replacement" do
    labels, clusters = user_label_writes
    append = user_label_data(Matter::Cluster::LabelStruct.new("room", "office").to_tlv, append: true)

    statuses = Matter::Protocol::IMHandler.write_attributes([append], clusters)

    statuses.first.status.status.should eq(Matter::InteractionModel::StatusCode::Busy.value)
    labels.label_list.should be_empty
  end

  it "rejects a numeric ListIndex without replacing the list" do
    labels, clusters = user_label_writes
    indexed = user_label_data(Matter::Cluster::LabelStruct.new("room", "office").to_tlv, index: 0_u16)

    statuses = Matter::Protocol::IMHandler.write_attributes([indexed], clusters)

    statuses.first.status.status.should eq(Matter::InteractionModel::StatusCode::InvalidAction.value)
    labels.label_list.should be_empty
  end

  it "does not treat an item without ListIndex as an append" do
    labels, clusters = user_label_writes
    item = user_label_data(Matter::Cluster::LabelStruct.new("room", "office").to_tlv)

    statuses = Matter::Protocol::IMHandler.write_attributes([item], clusters)

    statuses.first.status.status.should eq(Matter::InteractionModel::StatusCode::InvalidDataType.value)
    labels.label_list.should be_empty
  end
end
