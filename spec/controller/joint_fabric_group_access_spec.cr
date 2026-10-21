require "../spec_helper"
require "../../src/matter/controller"

private alias JointStore = Matter::Cluster::JointFabricDatastore

private class JointGroupImClient < Matter::Controller::ImClient
  getter commands = [] of UInt32

  def initialize(@store : JointStore)
    super(Matter::Controller::Client.new)
  end

  def close : Nil
    @client.close
  end

  def read_attribute(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
                     endpoint_id : UInt16, cluster_id : UInt32, attribute_id : UInt32,
                     fabric_filtered : Bool = true) : Matter::InteractionModel::ReportDataMessage
    value = case attribute_id
            when JointStore::ATTR_ANCHOR_ROOT_CA         then @store.anchor_root_ca.to_tlv
            when JointStore::ATTR_GROUP_LIST             then @store.group_list.to_tlv
            when JointStore::ATTR_ENDPOINT_GROUP_ID_LIST then @store.endpoint_group_id_list.to_tlv
            when JointStore::ATTR_NODE_ACL_LIST          then @store.node_acl_list.to_tlv
            else                                              raise Matter::ProtocolError.new("Unexpected Joint Fabric Datastore read")
            end
    path = Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id)
    data = Matter::InteractionModel::AttributeDataIB.new(path: path, data: TLV::Any.from_slice(value))
    Matter::InteractionModel::ReportDataMessage.new(attribute_reports: [Matter::InteractionModel::AttributeReportIB.new(attribute_data: data)])
  end

  def invoke(session : Matter::Session::SecureContext, peer : Socket::IPAddress,
             endpoint_id : UInt16, cluster_id : UInt32, command_id : UInt32,
             fields : Bytes = Bytes.empty, timed_request : Bool = false,
             timed_request_timeout : Time::Span = DEFAULT_TIMED_REQUEST_TIMEOUT) : Matter::InteractionModel::InvokeResponseMessage
    @commands << command_id
    result = case command_id
             when JointStore::CMD_ADD_GROUP
               @store.add_group(JointStore::AddGroupRequest.from_slice(fields))
             when JointStore::CMD_ADD_GROUP_ID_TO_ENDPOINT_FOR_NODE
               @store.add_group_id_to_endpoint_for_node(JointStore::AddGroupIDToEndpointForNodeRequest.from_slice(fields))
             when JointStore::CMD_ADD_ACL_TO_NODE
               @store.add_acl_to_node(JointStore::AddACLToNodeRequest.from_slice(fields))
             when JointStore::CMD_REFRESH_NODE
               @store.refresh_node(JointStore::RefreshNodeRequest.from_slice(fields))
             else
               raise Matter::ProtocolError.new("Unexpected Joint Fabric Datastore command")
             end
    path = Matter::InteractionModel::CommandPath.new(endpoint: endpoint_id, cluster: cluster_id, command: command_id)
    status = Matter::InteractionModel::CommandStatusIB.new(path,
      Matter::InteractionModel::StatusIB.new(result.status.value))
    Matter::InteractionModel::InvokeResponseMessage.new(invoke_responses: [Matter::InteractionModel::InvokeResponseIB.new(command_status: status)])
  end
end

describe Matter::Controller::SharedFabric do
  it "grants a Joint Fabric controller access through a Datastore CAT group" do
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(0x1234_u64, 0x100_u64, 0xFFF1_u16)
    authority = bootstrap.fabric
    delegated = Matter::Controller::SharedFabric.delegate_joint(authority, 0x101_u64, 0x1234_u16, 2_u16)
    expect_raises(Matter::ConfigurationError, /group CAT/) do
      Matter::Controller::SharedFabric.delegate_joint(authority, 0x102_u64, 0x1234_u16, UInt16::MAX)
    end
    expect_raises(Matter::ConfigurationError, /intermediate CA key/) do
      Matter::Controller::SharedFabric.delegate_joint(delegated, 0x102_u64, 0x1234_u16, 2_u16)
    end
    Matter::Crypto::MatterCertificate::Validation.verify_chain(
      delegated.controller_noc, delegated.intermediate_cert, authority.root_public_key, authority.root_cert)
    Matter::Crypto::MatterCertificate.subject_ids_from_tlv(delegated.controller_noc)
      .should contain(0xFFFF_FFFD_1234_0002_u64)

    datastore = JointStore.new(Matter::DataType::EndpointNumber.new(1_u16))
    datastore.configure_anchor(authority.root_cert, 0x100_u64, 0xFFF1_u16, "Anchor")
    datastore.add_pending_node(JointStore::AddPendingNodeRequest.new(0x200_u64, "Lamp"))
    datastore.record_endpoint(0x200_u64, 1_u16, "Light")
    im = JointGroupImClient.new(datastore)
    session = Matter::Session::SecureContext.new(
      session_id: 1_u16, peer_session_id: 1_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16),
      # Initiator CASE contexts do not know the remote fabric index.
      case_session: true)
    peer = Socket::IPAddress.new("127.0.0.1", 5540)

    Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
      datastore_endpoint: 1_u16, device_node_id: 0x200_u64, device_endpoint: 1_u16,
      group_id: 10_u16, group_name: "Controllers", controller: delegated)
    im.commands.should eq([JointStore::CMD_ADD_GROUP,
                           JointStore::CMD_ADD_GROUP_ID_TO_ENDPOINT_FOR_NODE, JointStore::CMD_ADD_ACL_TO_NODE])
    datastore.group_list.last.group_cat.should eq(0x1234_u16)
    datastore.group_list.last.group_cat_version.should eq(2_u16)
    datastore.node_acl_list.last.acl_entry.subjects.should eq([0xFFFF_FFFD_1234_0002_u64])

    Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
      datastore_endpoint: 1_u16, device_node_id: 0x200_u64, device_endpoint: 1_u16,
      group_id: 10_u16, group_name: "Controllers", controller: delegated)
    im.commands.size.should eq(3)

    datastore.complete_group_membership(0x200_u64, 1_u16, 10_u16, 1_u8).should be_true
    datastore.complete_acl(0x200_u64, datastore.node_acl_list.last.list_id, 1_u8).should be_true
    Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
      datastore_endpoint: 1_u16, device_node_id: 0x200_u64, device_endpoint: 1_u16,
      group_id: 10_u16, group_name: "Controllers", controller: delegated)
    im.commands.last.should eq(JointStore::CMD_REFRESH_NODE)
    datastore.node_acl_list.last.status_entry.state.should eq(JointStore::DatastoreStateEnum::Pending)

    datastore.add_group(JointStore::AddGroupRequest.new(11_u16, "Other group", nil, 0x2345_u16,
      1_u16, JointStore::DatastoreAccessControlEntryPrivilegeEnum::Administer))
    expect_raises(Matter::CommissioningError, /different CAT/) do
      Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
        datastore_endpoint: 1_u16, device_node_id: 0x200_u64, device_endpoint: 1_u16,
        group_id: 11_u16, group_name: "Controllers", controller: delegated)
    end
    expect_raises(Matter::CertificateError, /group CAT/) do
      Matter::Controller::SharedFabric.grant_joint_admin(im, session, peer,
        datastore_endpoint: 1_u16, device_node_id: 0x200_u64, device_endpoint: 1_u16,
        group_id: 12_u16, group_name: "Controllers", controller: authority)
    end
    im.commands.size.should eq(4)
  ensure
    im.try(&.close)
  end
end
