require "../spec_helper"

private def list_index_element(path : Matter::InteractionModel::AttributePath) : TLV::Any?
  TLV::Any.from_slice(path.to_slice).value.as(TLV::List).find { |element| element.header.ids == 5_u8 }
end

describe Matter::InteractionModel::AttributePath do
  it "omits ListIndex for a whole-list replacement path" do
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 0x41_u32, attribute: 0_u32)
    list_index_element(path).should be_nil
  end

  it "preserves an explicit null ListIndex for an append path" do
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 0x41_u32, attribute: 0_u32)
    raw = TLV::Any.from_slice(path.to_slice)
    elements = raw.value.as(TLV::List)
    elements << TLV::Serializable.serialize_value(nil, 5_u8)

    decoded = Matter::InteractionModel::AttributePath.from_tlv(raw)
    list_index_element(decoded).try(&.header.element_type.null?).should be_true
  end

  it "preserves a numeric ListIndex distinctly from null" do
    path = Matter::InteractionModel::AttributePath.new(endpoint: 1_u16, cluster: 0x41_u32, attribute: 0_u32, list_index: 2_u16)
    list_index_element(path).try(&.as_u16).should eq(2_u16)
    Matter::InteractionModel::AttributePath.from_slice(path.to_slice).list_index.should eq(2_u16)
  end

  it "carries an explicit append path through a WriteRequest" do
    path = Matter::InteractionModel::AttributePath.new(
      endpoint: 1_u16, cluster: 0x41_u32, attribute: 0_u32, list_index_null: true
    )
    data = Matter::InteractionModel::AttributeDataIB.new(path, TLV::Any.new(7_u8))
    request = Matter::InteractionModel::WriteRequestMessage.new(write_requests: [data])

    decoded = Matter::InteractionModel::WriteRequestMessage.from_slice(request.to_slice)
    decoded_path = decoded.write_requests.as(Array(Matter::InteractionModel::AttributeDataIB)).first.path
    decoded_path.list_index_null?.should be_true
    list_index_element(decoded_path).try(&.header.element_type.null?).should be_true
  end
end
