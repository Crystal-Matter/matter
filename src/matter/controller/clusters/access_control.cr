require "json"

require "../../cluster/access_control"

module Matter
  module Controller
    module Clusters
      module AccessControl
        alias Entry = Matter::Cluster::AccessControl::AccessControlEntry
        alias Target = Matter::Cluster::AccessControl::Target
        alias Privilege = Matter::Cluster::AccessControl::AccessControlEntryPrivilege
        alias AuthMode = Matter::Cluster::AccessControl::AccessControlEntryAuthMode
        alias AuxiliaryType = Matter::Cluster::AccessControl::AccessControlAuxiliaryType

        struct TargetJson
          include JSON::Serializable

          @[JSON::Field(key: "endpoint")]
          getter endpoint : UInt16?

          @[JSON::Field(key: "cluster")]
          getter cluster : UInt32?

          @[JSON::Field(key: "deviceType")]
          getter device_type : UInt32?
        end

        struct EntryJson
          include JSON::Serializable

          getter privilege : UInt8

          @[JSON::Field(key: "authMode")]
          getter auth_mode : UInt8

          getter subjects : Array(UInt64)

          getter targets : Array(TargetJson)?

          @[JSON::Field(key: "auxiliaryType")]
          getter auxiliary_type : UInt8?
        end

        # Parses the JSON format used by CHIP's `chip-tool accesscontrol write acl ...`
        # and returns entries suitable for encoding into a TLV list for WriteRequest.
        #
        # Supported keys:
        # - privilege (UInt8)
        # - authMode (UInt8)
        # - subjects (array of UInt64)
        # - targets (null or array of {endpoint, cluster, deviceType})
        # - fabricIndex (ignored; server derives from session)
        def self.parse_acl_json(json : String) : Array(Entry)
          entries = Array(EntryJson).from_json(json)

          mapped = entries.each_with_index.map do |obj, idx|
            if obj.auxiliary_type
              raise ArgumentError.new("AuxiliaryType is not permitted in a primary ACL write")
            end
            privilege = Privilege.from_value(obj.privilege.to_i)
            auth_mode = AuthMode.from_value(obj.auth_mode.to_i)

            targets = obj.targets.try do |arr|
              arr.map do |target|
                Target.new(
                  cluster: target.cluster,
                  endpoint: target.endpoint,
                  device_type: target.device_type
                )
              end
            end

            Entry.new(
              privilege: privilege,
              auth_mode: auth_mode,
              subjects: obj.subjects,
              targets: targets,
              fabric_index: nil
            )
          rescue ex
            raise ArgumentError.new("Invalid ACL JSON entry at index #{idx}: #{ex.message}")
          end

          mapped.to_a
        end

        def self.encode_acl_tlv(entries : Array(Entry)) : Bytes
          entries.to_tlv
        end
      end
    end
  end
end
