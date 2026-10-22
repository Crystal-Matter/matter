require "../spec_helper"
require "../../src/matter/controller"

describe "IM write request encoding" do
  it "round-trips a WriteRequest and yields typed attribute data usable by clusters" do
    json = %([{"privilege":1,"authMode":2,"subjects":[1],"targets":null}])
    entries = Matter::Controller::Clusters::AccessControl.parse_acl_json(json)
    tlv = Matter::Controller::Clusters::AccessControl.encode_acl_tlv(entries)

    path = Matter::InteractionModel::AttributePath.new(
      endpoint: 0_u16,
      cluster: Matter::Cluster::AccessControl::CLUSTER_ID,
      attribute: Matter::Cluster::AccessControl::ATTR_ACL
    )

    attr = Matter::InteractionModel::AttributeDataIB.new(path: path, data: TLV::Any.from_slice(tlv))
    msg = Matter::InteractionModel::WriteRequestMessage.new(
      suppress_response: false,
      timed_request: false,
      write_requests: [attr],
      more_chunked_messages: false,
      interaction_model_revision: 12_u8
    )

    parsed = Matter::Protocol::IMHandler.parse_write_request(msg.to_slice)
    parsed.should_not be_nil

    req = parsed.as(Matter::InteractionModel::WriteRequestMessage)
    write_requests = req.write_requests || [] of Matter::InteractionModel::AttributeDataIB
    write_requests.size.should eq 1

    cluster = build(Matter::Cluster::AccessControl, 0)
    status = write(cluster, Matter::Cluster::AccessControl::ATTR_ACL, write_requests[0].data,
      is_case_session: true, fabric_index: 1_u8, peer_subject_ids: [1_u64])
    status.status.should eq Matter::InteractionModel::StatusCode::Success
  end
end
