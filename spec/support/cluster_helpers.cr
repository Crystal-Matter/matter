# Shared helpers for typed TLV cluster reads, writes and commands.

# Records one `on_attribute_changed` notification, see `capture_changes`.
record AttributeChange, endpoint : UInt16, cluster : UInt32, attribute : UInt32

# `endpoint(1)` is shorthand for `Matter::DataType::EndpointNumber.new(1_u16)`.
def endpoint(number : Int) : Matter::DataType::EndpointNumber
  Matter::DataType::EndpointNumber.new(number.to_u16)
end

# Constructs a cluster on `endpoint(number)`, forwarding any keyword arguments
# to its constructor. The concrete class is returned, so cluster-specific
# methods stay available:
#
#   build(Matter::Cluster::OnOff)                    # endpoint 1, defaults
#   build(Matter::Cluster::Descriptor, 0)            # endpoint 0
#   build(Matter::Cluster::OnOff, on_off: true)      # endpoint 1, initial state
def build(klass : T.class, endpoint : Int = 1, **kwargs) forall T
  klass.new(endpoint(endpoint), **kwargs)
end

# Build the IM cluster index for a CASE fixture with an explicit administrator
# grant. Tests of cluster behavior use this to satisfy the mandatory ACL gate;
# access-control tests construct their own ACL and grants instead.
def case_im_clusters(cluster : Matter::Cluster::Base, *, fabric_index : UInt8 = 1_u8,
                     subject_id : UInt64 = 11_u64) : Hash(Tuple(UInt16, UInt32), Matter::Cluster::Base)
  acl = Matter::Cluster::AccessControl.new(Matter::DataType::EndpointNumber::ROOT)
  acl.acl << Matter::Cluster::AccessControl::AccessControlEntry.new(
    Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
    Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
    [subject_id], nil, fabric_index)
  {
    {Matter::Node::ROOT_ENDPOINT_ID, Matter::Cluster::AccessControl::CLUSTER_ID} => acl.as(Matter::Cluster::Base),
    {cluster.endpoint_id.number, cluster.cluster_id.id} => cluster,
  }
end

# Reads an attribute and returns it as a `TLV::Any`, for lists and structures
# (`read_tlv(cluster, id).as_list`, `LabelStruct.from_tlv(read_tlv(...))`).
# Raises when the cluster answers with a status instead of a value.
def read_tlv(cluster : Matter::Cluster::Base, attribute_id : UInt32, fabric_index : UInt8? = nil) : TLV::Any
  case result = cluster.read_attribute(attribute_id, fabric_index)
  in TLV::Any
    result
  in Matter::InteractionModel::Status
    raise "#{cluster.name} read of attribute 0x#{attribute_id.to_s(16)} returned #{result.status}"
  end
end

# Reads an attribute and returns the decoded scalar value (`true`, `100_u8`,
# `"label"`, `nil`, ...). Raises when the cluster answers with a status.
def read(cluster : Matter::Cluster::Base, attribute_id : UInt32, fabric_index : UInt8? = nil)
  read_tlv(cluster, attribute_id, fabric_index).value
end

# Reads an attribute expecting a status (e.g. UnsupportedAttribute).
# Raises when the cluster answers with a value instead.
def read_status(cluster : Matter::Cluster::Base, attribute_id : UInt32, fabric_index : UInt8? = nil) : Matter::InteractionModel::Status
  case result = cluster.read_attribute(attribute_id, fabric_index)
  in Matter::InteractionModel::Status
    result
  in TLV::Any
    raise "#{cluster.name} read of attribute 0x#{attribute_id.to_s(16)} returned a value (#{result.inspect}), expected a status"
  end
end

# Writes an attribute through the same path a network write takes: the value is
# encoded into a WriteRequest, re-parsed, then dispatched with its TLV type
# preserved by `IMHandler.write_attributes`.
# Accepts anything with `#to_tlv` (Int, Bool, String, Nil, Bytes, Array,
# `TLV::Serializable` structs) or a ready-made `TLV::Any`.
# Note: the IM path only carries the IM status code, so `cluster_status` is
# not available on the returned status.
def write(cluster : Matter::Cluster::Base, attribute_id : UInt32, value,
          is_case_session : Bool = false, fabric_index : UInt8? = nil,
          peer_subject_ids : Array(UInt64)? = nil) : Matter::InteractionModel::Status
  data = TLV::Serializable.serialize_value(value, nil)
  endpoint_id = cluster.endpoint_id.number
  cluster_id = cluster.cluster_id.id

  request = Matter::InteractionModel::WriteRequestMessage.new(
    suppress_response: false,
    timed_request: false,
    write_requests: [
      Matter::InteractionModel::AttributeDataIB.new(
        path: Matter::InteractionModel::AttributePath.new(endpoint: endpoint_id, cluster: cluster_id, attribute: attribute_id),
        data: data,
      ),
    ],
  )
  parsed = Matter::Protocol::IMHandler.parse_write_request(request.to_slice)
  raise "failed to parse WriteRequest for attribute 0x#{attribute_id.to_s(16)}" unless parsed

  results = Matter::Protocol::IMHandler.write_attributes(parsed.write_requests,
    { {endpoint_id, cluster_id} => cluster }, is_case_session: is_case_session,
    fabric_index: fabric_index, peer_subject_ids: peer_subject_ids)
  status_ib = results.first.status
  Matter::InteractionModel::Status.new(Matter::InteractionModel::StatusCode.new(status_ib.status), status_ib.cluster_status)
end

# Invokes a command. `request` may be omitted (no fields), raw `Bytes`, or any
# `TLV::Serializable` request struct. Session context is forwarded unchanged.
def invoke(cluster : Matter::Cluster::Base, command_id : UInt32, request = nil, session_id : UInt64? = nil, is_case_session : Bool = false, fabric_index : UInt8? = nil) : Matter::InteractionModel::Status | Matter::Cluster::CommandResponse
  fields = case request
           when Nil then nil
           when Bytes
             request.empty? ? nil : TLV::Any.from_slice(request)
           else TLV::Serializable.serialize_value(request, nil)
           end
  cluster.invoke_command(command_id, fields, session_id: session_id, is_case_session: is_case_session, fabric_index: fabric_index)
end

# Invokes a command and decodes its `CommandResponse` payload as `response_class`
# (e.g. `invoke_response(lock, CMD_GET_USER, req, Def::GetUserResponse)`).
# Raises when the cluster answers with a status instead of a response.
def invoke_response(cluster : Matter::Cluster::Base, command_id : UInt32, request, response_class : T.class) forall T
  case result = invoke(cluster, command_id, request)
  in Matter::Cluster::CommandResponse
    response_class.from_tlv(result.response.as(TLV::Any))
  in Matter::InteractionModel::Status
    raise "#{cluster.name} command 0x#{command_id.to_s(16)} returned #{result.status}, expected a #{response_class}"
  end
end

# Asserts that a read/write/invoke result is a `Status` with the given code,
# with a message that names the actual status (or response) on failure.
def expect_status(result : Matter::InteractionModel::Status | Matter::Cluster::CommandResponse, expected : Matter::InteractionModel::StatusCode, file = __FILE__, line = __LINE__) : Matter::InteractionModel::Status
  case result
  in Matter::InteractionModel::Status
    result.status.should eq(expected), file: file, line: line
    result
  in Matter::Cluster::CommandResponse
    fail "expected status #{expected}, got CommandResponse(0x#{result.command_id.to_s(16)})", file, line
  end
end

# Asserts a successful `Status`.
def expect_success(result : Matter::InteractionModel::Status | Matter::Cluster::CommandResponse, file = __FILE__, line = __LINE__) : Matter::InteractionModel::Status
  expect_status(result, Matter::InteractionModel::StatusCode::Success, file, line)
end

# The ids reported by the global AttributeList / AcceptedCommandList /
# GeneratedCommandList attributes, decoded to `Array(UInt32)`.
def attribute_ids(cluster : Matter::Cluster::Base) : Array(UInt32)
  read_tlv(cluster, Matter::Cluster::Base::GLOBAL_ATTRIBUTE_LIST).as_list.map(&.as_u32)
end

def accepted_command_ids(cluster : Matter::Cluster::Base) : Array(UInt32)
  read_tlv(cluster, Matter::Cluster::Base::GLOBAL_ACCEPTED_COMMAND_LIST).as_list.map(&.as_u32)
end

def generated_command_ids(cluster : Matter::Cluster::Base) : Array(UInt32)
  read_tlv(cluster, Matter::Cluster::Base::GLOBAL_GENERATED_COMMAND_LIST).as_list.map(&.as_u32)
end

# Records every `on_attribute_changed` notification raised while the block
# runs, restoring the previous callback afterwards:
#
#   changes = capture_changes(cluster) { cluster.update_state(true) }
#   changes.map(&.attribute).should contain(ATTR_STATE_VALUE)
def capture_changes(cluster : Matter::Cluster::Base, &) : Array(AttributeChange)
  changes = [] of AttributeChange
  previous = cluster.on_attribute_changed
  cluster.on_attribute_changed = ->(ep : UInt16, cl : UInt32, attr : UInt32) { changes << AttributeChange.new(ep, cl, attr); nil }
  yield
  changes
ensure
  cluster.on_attribute_changed = previous
end

# How much `data_version` advanced while the block ran.
def version_delta(cluster : Matter::Cluster::Base, &) : Int64
  before = cluster.data_version
  yield
  cluster.data_version.to_i64 - before.to_i64
end
