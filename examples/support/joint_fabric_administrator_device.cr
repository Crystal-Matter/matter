require "../../src/matter/node"
require "./console"
require "../../src/matter/commissioning/joint_fabric_administrator_service"
require "../../src/matter/commissioning/joint_fabric_add_noc_policy"
require "../../src/matter/controller/datastore_propagator"
require "../../src/matter/controller/anchor_datastore_subscription"
require "../../src/matter/controller/joint_commissioning"
require "../../src/matter/controller/anchor_transfer"
require "../../src/matter/controller/administrator_removal"
require "../../src/matter/controller/joint_fabric_device_migration"
require "../../src/matter/controller/vid_verification_dcl"

# Joint Fabric Administrator endpoint for interoperability work. Commission
# this device onto an Anchor fabric first; its JF service binds to that fabric
# as soon as the RCAC and operational credentials are installed.
module MatterJointFabricAdministrator
  EXAMPLE_PRODUCT_ID = 0x0130_u16

  # The SDK migration E2E counts completion and removal commands. When a
  # shared marker is armed, it withholds the matching successful SDK reply
  # before MRP acknowledgement or workflow delivery.
  class SdkMigrationReplyLossClient < Matter::Controller::Client
    def initialize(@drop_path : String, @remove_drop_path : String? = nil)
      super()
    end

    def send_encrypted_request(session : Matter::Session::SecureContext,
                               peer : Socket::IPAddress, protocol_id : UInt16,
                               message_type : UInt8, payload : Bytes | Slice(UInt8),
                               exchange_id : UInt16 = next_exchange_id,
                               initiator_message : Bool = true,
                               requires_ack : Bool = true,
                               acknowledged_message_id : UInt32? = nil) : UInt16
      if protocol_id == PROTOCOL_INTERACTION_MODEL &&
         message_type == Matter::InteractionModel::MessageType::InvokeRequest.value
        paths = Matter::InteractionModel::InvokeRequestMessage.from_slice(payload.to_slice)
          .invoke_requests.map(&.command_path)
        if paths.any? { |path| path.cluster == Matter::Cluster::GeneralCommissioning::CLUSTER_ID &&
           path.command == Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE }
          if File.exists?(@drop_path)
            @lost_exchange = exchange_id
            @lost_session_id = session.session_id
          end
          count_path = "#{@drop_path}.sent"
          sent = File.exists?(count_path) ? File.read(count_path).to_i : 0
          File.write(count_path, (sent + 1).to_s)
        end
        if remove_path = @remove_drop_path
          if paths.any? { |path| path.cluster == Matter::Cluster::OperationalCredentials::CLUSTER_ID &&
             path.command == Matter::Cluster::OperationalCredentials::CMD_REMOVE_FABRIC }
            if File.exists?(remove_path)
              @lost_remove_exchange = exchange_id
              @lost_remove_session_id = session.session_id
            end
            count_path = "#{remove_path}.sent"
            sent = File.exists?(count_path) ? File.read(count_path).to_i : 0
            File.write(count_path, (sent + 1).to_s)
          end
        end
      end
      super(session, peer, protocol_id, message_type, payload, exchange_id,
        initiator_message, requires_ack, acknowledged_message_id)
    end

    protected def drop_authenticated_inbound?(message : Matter::Codec::MessageCodec::Message,
                                              _peer : Socket::IPAddress) : Bool
      return false unless message.payload_header.protocol_id == PROTOCOL_INTERACTION_MODEL &&
                          message.payload_header.message_type == Matter::InteractionModel::MessageType::InvokeResponse.value
      completion_reply = message.packet_header.session_id == @lost_session_id &&
                         message.payload_header.exchange_id == @lost_exchange
      removal_reply = message.packet_header.session_id == @lost_remove_session_id &&
                      message.payload_header.exchange_id == @lost_remove_exchange
      return false unless completion_reply || removal_reply
      response = Matter::InteractionModel::InvokeResponseMessage.from_slice(message.payload.to_slice)
      successful_reply = response.invoke_responses.any? do |entry|
        if command = entry.command_data
          path = command.command_path
          if completion_reply && path.cluster == Matter::Cluster::GeneralCommissioning::CLUSTER_ID &&
             path.command == Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE_RESPONSE
            fields = command.command_fields
            fields && Matter::Cluster::GeneralCommissioning::CommissioningCompleteResponse
              .from_slice(fields.to_slice).error_code == Matter::Commissioning::ErrorCode::OK
          elsif removal_reply && path.cluster == Matter::Cluster::OperationalCredentials::CLUSTER_ID &&
                path.command == Matter::Cluster::OperationalCredentials::CMD_ADD_NOC_RESPONSE
            fields = command.command_fields
            fields && Matter::Cluster::OperationalCredentials::Tlv::TlvNocResponse
              .from_slice(fields.to_slice).status_code.ok?
          else
            false
          end
        else
          false
        end
      end
      return false unless successful_reply
      if completion_reply
        File.write("#{@drop_path}.dropped", "successful SDK CommissioningComplete response\n")
      elsif remove_path = @remove_drop_path
        File.write("#{remove_path}.dropped", "successful SDK RemoveFabric response\n")
      end
      true
    end
  end

  class Device < Matter::Device
    include Examples::Console

    alias Admin = Matter::Cluster::JointFabricAdministrator
    alias Datastore = Matter::Cluster::JointFabricDatastore

    APP_KEY_DOCUMENT                      = "joint-fabric-admin-key"
    APP_ICAC_DOCUMENT                     = "joint-fabric-admin-icac"
    APP_ROLE_DOCUMENT                     = "joint-fabric-admin-role"
    APP_BOOTSTRAP_ROLE_DOCUMENT           = "joint-fabric-bootstrap-role"
    APP_BOOTSTRAP_ICAC_DOCUMENT           = "joint-fabric-bootstrap-icac"
    APP_BOOTSTRAP_TRANSFER_WATCH_DOCUMENT = "joint-fabric-bootstrap-transfer-watch"
    APP_FABRIC_BINDING_DOCUMENT           = "joint-fabric-admin-binding"
    APP_BOOTSTRAP_BINDING_DOCUMENT        = "joint-fabric-bootstrap-binding"
    APP_TRANSFER_DOCUMENT                 = "joint-fabric-anchor-transfer"
    APP_TRANSFER_WATCH_DOCUMENT           = "joint-fabric-transfer-watch"
    APP_FOLLOW_UP_PREFIX                  = "joint-fabric-anchor-follow-up-"
    APP_REMOVAL_PREFIX                    = "joint-fabric-administrator-removal-"
    APP_PARTICIPANT_RECOVERY_FENCE        = "joint-fabric-participant-recovery-fence"
    APP_PARTICIPANT_RECOVERY_RELEASE      = "joint-fabric-participant-recovery-release"
    JCM_RPC_COLLECTION                    = "jcm_anchor_exchange"
    JCM_RPC_REQUEST                       = "request"
    JCM_RPC_RESULT                        = "result"
    COMMAND_RPC_COLLECTION                = "jfa_command"
    ADMINISTRATOR_CAT_ID                  = Matter::Cluster::JointFabricDatastore::ADMINISTRATOR_CAT
    ANCHOR_CAT_ID                         = Matter::Cluster::JointFabricDatastore::ANCHOR_CAT
    ADMINISTRATOR_CAT_SUBJECT_PREFIX      = Matter::DataType::NodeId::CAT_PREFIX |
                                            (ADMINISTRATOR_CAT_ID.to_u64 << Matter::DataType::CaseAuthenticatedTag::IDENTITY_SHIFT)
    DEFAULT_OPERATIONAL_PORT     =    5540
    ADMIN_GROUP_ID               =   1_u16
    ANCHOR_GROUP_ID              =   2_u16
    ANCHOR_IPK_KEY_SET_ID        =   0_u16
    ANCHOR_JFA_ENDPOINT_ID       =   1_u16
    BOOTSTRAP_JFA_ENDPOINT_ID    =   2_u16
    UNCOMPRESSED_P256_POINT_TAG  = 0x04_u8
    ROTATION_NONCE_HEX_LENGTH    = Matter::Controller::VidVerification::CHALLENGE_SIZE * 2
    PARTICIPANT_WITNESS_TIMEOUT  = 30.seconds
    DEFAULT_ANCHOR_FRIENDLY_NAME = "Crystal Anchor"

    struct ParticipantRecoveryFence
      include Matter::Storage::Record

      getter lease_id : String
      getter anchor_node_id : UInt64
      getter outgoing_node_id : UInt64
      getter participant_node_id : UInt64
      getter fabric_id : UInt64
      getter root_public_key : Bytes
      getter credential : Bytes

      def initialize(@lease_id : String, @anchor_node_id : UInt64,
                     @outgoing_node_id : UInt64, @participant_node_id : UInt64,
                     @fabric_id : UInt64, @root_public_key : Bytes,
                     @credential : Bytes)
      end

      def same_request?(other : ParticipantRecoveryFence) : Bool
        lease_id == other.lease_id && anchor_node_id == other.anchor_node_id &&
          outgoing_node_id == other.outgoing_node_id && participant_node_id == other.participant_node_id &&
          fabric_id == other.fabric_id && root_public_key == other.root_public_key &&
          credential == other.credential
      end
    end

    struct IcacKeyState
      include Matter::Storage::Record

      getter private_key : Bytes
      getter public_key : Bytes

      def initialize(@private_key : Bytes, @public_key : Bytes)
      end
    end

    struct IcacCertificateState
      include Matter::Storage::Record

      getter certificate : Bytes

      def initialize(@certificate : Bytes)
      end
    end

    struct JointFabricRoleState
      include Matter::Storage::Record

      getter? anchor : Bool
      # A pre-upgrade role record without this field must fail closed rather
      # than re-expose a former Anchor's frozen Datastore after restart.
      getter? transfer_complete : Bool = true

      def initialize(@anchor : Bool, @transfer_complete : Bool = false)
      end
    end

    struct FabricBindingState
      include Matter::Storage::Record

      getter fabric_index : UInt8
      getter fabric_id : UInt64
      getter root_public_key : Bytes

      def initialize(@fabric_index : UInt8, @fabric_id : UInt64, @root_public_key : Bytes)
      end

      def matches?(fabric : Matter::Fabric) : Bool
        @fabric_index == fabric.fabric_index && @fabric_id == fabric.fabric_id &&
          @root_public_key == fabric.root_public_key
      end
    end

    struct TransferWatchState
      include Matter::Storage::Record

      getter requester_node_id : UInt64
      getter old_fabric_id : UInt64
      getter old_root_public_key : Bytes
      getter new_anchor_node_id : UInt64?

      def initialize(@requester_node_id : UInt64, @old_fabric_id : UInt64,
                     @old_root_public_key : Bytes, @new_anchor_node_id : UInt64?)
      end
    end

    # Local controller-to-JFA handoff used by the e2e example. The controller
    # has already verified the joining ICAC public key before writing this.
    struct AnchorExchangeRequest
      include Matter::Storage::Record

      getter joining_node_id : UInt64
      getter fabric_id : UInt64
      getter root_public_key : Bytes
      getter peer_address : String
      getter peer_port : Int32
      getter administrator_endpoint : UInt16
      getter icac_public_key : Bytes
      getter icac_id : UInt64

      def initialize(@fabric_id : UInt64, @root_public_key : Bytes,
                     @joining_node_id : UInt64, @peer_address : String,
                     @peer_port : Int32, @administrator_endpoint : UInt16,
                     @icac_public_key : Bytes, @icac_id : UInt64)
      end

      def initialize(fabric_id : UInt64, root_public_key : Bytes,
                     joining_node_id : UInt64, peer : Socket::IPAddress,
                     administrator_endpoint : UInt16, icac_public_key : Bytes,
                     icac_id : UInt64)
        initialize(fabric_id, root_public_key, joining_node_id,
          Matter::Controller::OperationalPeerResolver.address_hint(peer), peer.port,
          administrator_endpoint, icac_public_key, icac_id)
      end
    end

    struct AnchorExchangeResult
      include Matter::Storage::Record

      getter status : String
      getter certificate : Bytes?
      getter error : String?

      def initialize(@status : String, @certificate : Bytes? = nil, @error : String? = nil)
      end
    end

    # File-backed local command channel for headless interoperability runs.
    # The application must explicitly set MATTER_JFA_COMMAND_PATH to enable it.
    struct CommandRequest
      include Matter::Storage::Record

      getter operation : String
      getter node_id : UInt64
      getter fabric_id : UInt64?
      getter root_public_key : Bytes?
      getter old_fabric_id : UInt64? = nil
      getter old_root_public_key : Bytes? = nil
      getter nonce : String?
      getter? interrupt_after_remove_fabric : Bool
      # Older command-channel YAML files predate these test-only fault hooks.
      getter? interrupt_after_remove_admin : Bool = false
      getter? interrupt_before_remove_admin : Bool = false
      getter? interrupt_before_transfer_follow_up : Bool = false
      getter? interrupt_after_first_transfer_follow_up : Bool = false
      getter? interrupt_after_next_transfer_cross_sign : Bool = false
      getter? interrupt_after_next_transfer_old_fabric_removed : Bool = false
      getter? interrupt_before_next_transfer_cross_sign_journal : Bool = false
      getter? interrupt_before_next_transfer_pending_icac_journal : Bool = false
      getter? interrupt_after_transfer_request : Bool = false
      getter? interrupt_before_transfer_copy_journal : Bool = false
      getter? interrupt_after_transfer_copy : Bool = false
      getter? interrupt_after_transfer_rotation : Bool = false
      getter? interrupt_after_first_transfer_administrator_rotation : Bool = false
      getter? interrupt_after_second_transfer_administrator_rotation : Bool = false
      getter? interrupt_after_transfer_promotion : Bool = false
      getter? interrupt_after_transfer_complete : Bool = false
      getter? interrupt_after_anchor_rotation : Bool = false
      getter? interrupt_before_anchor_noc : Bool = false
      getter? interrupt_after_participant_rotation : Bool = false
      getter? interrupt_before_participant_noc : Bool = false
      getter? interrupt_before_participant_rewind_save : Bool = false
      getter? interrupt_after_participant_rewind_save : Bool = false
      getter? interrupt_after_migration_complete_before_ack : Bool = false
      getter? interrupt_after_migration_add_noc_before_complete : Bool = false
      getter? interrupt_after_migration_failsafe_recorded : Bool = false
      getter? interrupt_after_migration_anchor_node_committed : Bool = false
      getter? interrupt_after_migration_anchor_node_removed : Bool = false
      getter? interrupt_after_migration_anchor_fabric_removed : Bool = false
      getter? interrupt_before_migration_anchor_verified : Bool = false
      getter? interrupt_before_migration_old_fabric_removed : Bool = false
      getter? interrupt_after_migration_old_fabric_removed : Bool = false
      getter? interrupt_before_migration_old_node_removed : Bool = false
      getter? interrupt_after_migration_old_node_removed : Bool = false
      getter fail_safe_max_seconds : UInt16? = nil
      getter test_friendly_name : String? = nil
      getter? jcm : Bool
      getter trusted_icac_public_key_b : Bytes?
      getter peer_admin_jfa_endpoint_id : UInt16?
      getter anchor_node_id : UInt64?
      getter peer_address : String?
      getter peer_port : Int32?
      getter rotation_target_node_id : UInt64? = nil
      getter recovery_lease_id : String? = nil
      getter recovery_outgoing_node_id : UInt64? = nil
      getter recovery_anchor_node_id : UInt64? = nil
      getter recovery_credential : Bytes? = nil

      def initialize(@operation : String, @node_id : UInt64,
                     @fabric_id : UInt64? = nil, @root_public_key : Bytes? = nil,
                     @nonce : String? = nil, @interrupt_after_remove_fabric : Bool = false,
                     @jcm : Bool = false, @trusted_icac_public_key_b : Bytes? = nil,
                     @peer_admin_jfa_endpoint_id : UInt16? = nil,
                     @anchor_node_id : UInt64? = nil, @peer_address : String? = nil,
                     @peer_port : Int32? = nil,
                     @rotation_target_node_id : UInt64? = nil,
                     @recovery_lease_id : String? = nil,
                     @recovery_outgoing_node_id : UInt64? = nil,
                     @recovery_anchor_node_id : UInt64? = nil,
                     @recovery_credential : Bytes? = nil,
                     @interrupt_after_remove_admin : Bool = false,
                     @interrupt_before_remove_admin : Bool = false,
                     @interrupt_before_transfer_follow_up : Bool = false,
                     @interrupt_after_first_transfer_follow_up : Bool = false,
                     @interrupt_after_next_transfer_cross_sign : Bool = false,
                     @interrupt_after_next_transfer_old_fabric_removed : Bool = false,
                     @interrupt_before_next_transfer_cross_sign_journal : Bool = false,
                     @interrupt_before_next_transfer_pending_icac_journal : Bool = false,
                     @interrupt_after_transfer_request : Bool = false,
                     @interrupt_before_transfer_copy_journal : Bool = false,
                     @interrupt_after_transfer_copy : Bool = false,
                     @interrupt_after_transfer_rotation : Bool = false,
                     @interrupt_after_first_transfer_administrator_rotation : Bool = false,
                     @interrupt_after_second_transfer_administrator_rotation : Bool = false,
                     @interrupt_after_transfer_promotion : Bool = false,
                     @interrupt_after_transfer_complete : Bool = false,
                     @interrupt_after_anchor_rotation : Bool = false,
                     @interrupt_before_anchor_noc : Bool = false,
                     @interrupt_after_participant_rotation : Bool = false,
                     @interrupt_before_participant_noc : Bool = false,
                     @interrupt_before_participant_rewind_save : Bool = false,
                     @interrupt_after_participant_rewind_save : Bool = false,
                     @interrupt_after_migration_complete_before_ack : Bool = false,
                     @interrupt_after_migration_add_noc_before_complete : Bool = false,
                     @interrupt_after_migration_failsafe_recorded : Bool = false,
                     @interrupt_after_migration_anchor_node_committed : Bool = false,
                     @interrupt_after_migration_anchor_node_removed : Bool = false,
                     @interrupt_after_migration_anchor_fabric_removed : Bool = false,
                     @interrupt_before_migration_anchor_verified : Bool = false,
                     @interrupt_before_migration_old_fabric_removed : Bool = false,
                     @interrupt_after_migration_old_fabric_removed : Bool = false,
                     @interrupt_before_migration_old_node_removed : Bool = false,
                     @interrupt_after_migration_old_node_removed : Bool = false,
                     @fail_safe_max_seconds : UInt16? = nil,
                     @test_friendly_name : String? = nil,
                     @old_fabric_id : UInt64? = nil,
                     @old_root_public_key : Bytes? = nil)
      end
    end

    struct CommandResult
      include Matter::Storage::Record

      getter status : String
      getter error : String?
      getter fabric_present : Bool?
      getter inspected_fabric_id : UInt64?
      getter inspected_root_public_key : Bytes?
      getter inspected_root_certificate : Bytes?
      getter inspected_icac_certificate : Bytes?
      getter inspected_node_id : UInt64?
      getter inspected_cross_signed_icac : Bytes?
      getter inspected_old_fabric_id : UInt64? = nil
      getter inspected_old_root_public_key : Bytes? = nil
      getter inspected_old_administrator_fabric_index : UInt8? = nil
      getter inspected_no_committed_cross_sign : Bool? = nil
      getter inspected_administrator_fabric_index : UInt8?
      getter inspected_fabric_count : Int32?
      getter inspected_datastore_admin_entries : Array(Bytes)?
      getter inspected_transfer_requester_node_id : UInt64?
      getter inspected_transfer_frozen : Bool?
      getter inspected_transfer_complete : Bool?
      getter inspected_new_anchor_node_id : UInt64?
      getter inspected_transfer_stage : UInt8?
      getter inspected_active_rotation_node_id : UInt64?
      getter inspected_follow_up_stage : UInt8?
      getter inspected_removal_stage : UInt8?
      getter inspected_removal_rotated_nodes : Array(UInt64)?
      getter inspected_failsafe_clear : Bool?
      getter inspected_credential_journal_clear : Bool?
      getter inspected_operational_credential : Bytes?
      getter inspected_jfa_endpoint_id : UInt16?
      getter inspected_recovery_lease_id : String?
      getter inspected_migration_stage : UInt8?
      getter inspected_controller_migration_node_present : Bool?
      getter nonce : String?
      getter certificate : Bytes?
      getter subscription_committed : Bool?

      def initialize(@status : String, @error : String? = nil, @fabric_present : Bool? = nil,
                     @inspected_fabric_id : UInt64? = nil,
                     @inspected_root_public_key : Bytes? = nil, @nonce : String? = nil,
                     @certificate : Bytes? = nil, @subscription_committed : Bool? = nil,
                     @inspected_root_certificate : Bytes? = nil,
                     @inspected_icac_certificate : Bytes? = nil,
                     @inspected_node_id : UInt64? = nil,
                     @inspected_cross_signed_icac : Bytes? = nil,
                     @inspected_old_fabric_id : UInt64? = nil,
                     @inspected_old_root_public_key : Bytes? = nil,
                     @inspected_old_administrator_fabric_index : UInt8? = nil,
                     @inspected_no_committed_cross_sign : Bool? = nil,
                     @inspected_administrator_fabric_index : UInt8? = nil,
                     @inspected_fabric_count : Int32? = nil,
                     @inspected_datastore_admin_entries : Array(Bytes)? = nil,
                     @inspected_transfer_requester_node_id : UInt64? = nil,
                     @inspected_transfer_frozen : Bool? = nil,
                     @inspected_transfer_complete : Bool? = nil,
                     @inspected_new_anchor_node_id : UInt64? = nil,
                     @inspected_transfer_stage : UInt8? = nil,
                     @inspected_active_rotation_node_id : UInt64? = nil,
                     @inspected_follow_up_stage : UInt8? = nil,
                     @inspected_removal_stage : UInt8? = nil,
                     @inspected_removal_rotated_nodes : Array(UInt64)? = nil,
                     @inspected_failsafe_clear : Bool? = nil,
                     @inspected_credential_journal_clear : Bool? = nil,
                     @inspected_operational_credential : Bytes? = nil,
                     @inspected_jfa_endpoint_id : UInt16? = nil,
                     @inspected_recovery_lease_id : String? = nil,
                     @inspected_migration_stage : UInt8? = nil,
                     @inspected_controller_migration_node_present : Bool? = nil)
      end

      # The private host channel carrying this record must authenticate the
      # participant. The nonce only binds a fresh result to this request.
      def proves_committed_cross_sign?(expected_nonce : String, expected_icac : Bytes,
                                       expected_fabric : Matter::Fabric,
                                       expected_node_id : UInt64,
                                       expected_endpoint_id : UInt16,
                                       expected_participant_fabric_index : UInt8) : Bool
        @status == "ok" && @nonce == expected_nonce &&
          @inspected_cross_signed_icac == expected_icac &&
          @inspected_fabric_id == expected_fabric.fabric_id &&
          @inspected_root_public_key == expected_fabric.root_public_key &&
          @inspected_node_id == expected_node_id &&
          @inspected_administrator_fabric_index == expected_participant_fabric_index &&
          @inspected_jfa_endpoint_id == expected_endpoint_id &&
          @inspected_failsafe_clear == true && @inspected_credential_journal_clear == true
      end

      def proves_uncommitted_cross_sign?(expected_nonce : String,
                                         expected_old_icac : Bytes,
                                         expected_new_fabric : Matter::Fabric,
                                         expected_old_fabric : Matter::Fabric,
                                         expected_node_id : UInt64,
                                         expected_endpoint_id : UInt16,
                                         expected_new_index : UInt8,
                                         expected_old_index : UInt8) : Bool
        @status == "ok" && @nonce == expected_nonce &&
          @inspected_no_committed_cross_sign == true &&
          @inspected_cross_signed_icac == expected_old_icac &&
          @inspected_fabric_id == expected_new_fabric.fabric_id &&
          @inspected_root_public_key == expected_new_fabric.root_public_key &&
          @inspected_old_fabric_id == expected_old_fabric.fabric_id &&
          @inspected_old_root_public_key == expected_old_fabric.root_public_key &&
          @inspected_node_id == expected_node_id &&
          @inspected_administrator_fabric_index == expected_new_index &&
          @inspected_old_administrator_fabric_index == expected_old_index &&
          @inspected_jfa_endpoint_id == expected_endpoint_id &&
          @inspected_failsafe_clear == true && @inspected_credential_journal_clear == true
      end

      def proves_participant_rotation_no_effect?(expected_nonce : String,
                                                 expected_credential : Bytes,
                                                 expected_fabric : Matter::Fabric,
                                                 expected_node_id : UInt64,
                                                 expected_fabric_index : UInt8) : Bool
        @status == "ok" && @nonce == expected_nonce &&
          @inspected_operational_credential == expected_credential &&
          @inspected_fabric_id == expected_fabric.fabric_id &&
          @inspected_root_public_key == expected_fabric.root_public_key &&
          @inspected_node_id == expected_node_id &&
          @inspected_administrator_fabric_index == expected_fabric_index &&
          @inspected_jfa_endpoint_id == ANCHOR_JFA_ENDPOINT_ID &&
          @inspected_failsafe_clear == true && @inspected_credential_journal_clear == true
      end
    end

    # Exercises the journal boundary where the remote RemoveFabric completed
    # but its acknowledgement was lost before the local stage could advance.
    class InterruptedRemovalPort < Matter::Controller::AdministratorRemoval::Port
      def initialize(@delegate : Matter::Controller::AdministratorRemoval::Port,
                     @interrupt_after_remove_fabric : Bool = false,
                     @interrupt_after_remove_admin : Bool = false,
                     @interrupt_after_anchor_rotation : Bool = false,
                     @interrupt_after_participant_rotation : Bool = false,
                     @interrupt_before_remove_admin : Bool = false,
                     @interrupt_before_participant_noc : Bool = false)
      end

      def remove_outgoing_fabric! : Nil
        @delegate.remove_outgoing_fabric!
        if @interrupt_after_remove_fabric
          raise Matter::TransportError.new("Injected lost RemoveFabric acknowledgement")
        end
      end

      def remove_datastore_admin! : Nil
        if @interrupt_before_remove_admin
          raise Matter::TransportError.new("Injected interruption before RemoveAdmin")
        end
        @delegate.remove_datastore_admin!
        if @interrupt_after_remove_admin
          raise Matter::TransportError.new("Injected lost RemoveAdmin acknowledgement")
        end
      end

      def rotate_anchor! : Nil
        @delegate.rotate_anchor!
        if @interrupt_after_anchor_rotation
          raise Matter::TransportError.new("Injected lost Anchor rotation acknowledgement")
        end
      end

      def rotate_participant!(node_id : UInt64) : Nil
        if @interrupt_before_participant_noc
          raise Matter::TransportError.new("Injected interruption before participant UpdateNOC")
        end
        @delegate.rotate_participant!(node_id)
        if @interrupt_after_participant_rotation
          raise Matter::TransportError.new("Injected lost participant rotation acknowledgement")
        end
      end
    end

    # Test-only loss of the TransferAnchorRequest acknowledgement. The old
    # Anchor is already frozen when the local journal remains Requesting.
    class InterruptedTransferPort < Matter::Controller::AnchorTransfer::Port
      def initialize(@delegate : Matter::Controller::AnchorTransfer::Port,
                     @interrupt_after_request : Bool = false,
                     @interrupt_after_complete : Bool = false)
      end

      def request : Admin::TransferAnchorResponseStatusEnum
        result = @delegate.request
        raise Matter::TransportError.new("Injected lost TransferAnchorRequest acknowledgement") if result.ok? && @interrupt_after_request
        result
      end

      def complete : Nil
        @delegate.complete
        raise Matter::TransportError.new("Injected lost TransferAnchorComplete acknowledgement") if @interrupt_after_complete
      end
    end

    identity vendor: "Crystal Matter", product: "Crystal Joint Fabric Administrator",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::JOINT_FABRIC_ADMINISTRATOR

    storage yaml: "matter_joint_fabric_administrator_storage.yml"
    network :ethernet

    endpoint ANCHOR_JFA_ENDPOINT_ID, device_type: Matter::DeviceType::JOINT_FABRIC_ADMINISTRATOR do
      cluster Admin, as: :joint_fabric_administrator
      cluster Datastore, as: :joint_fabric_datastore
    end

    # A joining Administrator retains its bootstrap fabric's Datastore while
    # endpoint 1 is rebound to the joined Anchor fabric. The two instances
    # enforce their own CASE fabric indices.
    endpoint BOOTSTRAP_JFA_ENDPOINT_ID, device_type: Matter::DeviceType::JOINT_FABRIC_ADMINISTRATOR do
      cluster Admin, as: :bootstrap_joint_fabric_administrator
      cluster Datastore, as: :bootstrap_joint_fabric_datastore
    end

    @anchor_role : Bool = false
    @joint_fabric_provisioned : Bool = false
    @datastore_propagator : Matter::Controller::DatastorePropagator?
    @bootstrap_datastore_propagator : Matter::Controller::DatastorePropagator?
    @migration_attestation_trust : Matter::Controller::AttestationTrustStore?
    @controller_store : Matter::Controller::StateStore?
    @propagation_fabric : Matter::Fabric?
    @propagation_started : Bool = false
    @transfer_in_progress : Bool = false
    @removal_in_progress : Bool = false
    @jcm_failsafe_session_id : UInt64?
    @new_anchor_subscription : Matter::Controller::AnchorDatastoreSubscription?
    @new_anchor_scanner : Matter::Controller::Scanner?
    @subscribed_fabric_id : UInt64?
    @subscribed_root_public_key : Bytes?
    @participant_view_current : Bool = false
    @watch_polling : Bool = false
    @watch_stopped : Bool = false
    @unprovisioned_service_fabric_index : UInt8?
    @participant_recovery_fence : ParticipantRecoveryFence?
    @participant_recovery_fence_uncertain : Bool = false
    @host_credential_exchange_lock = Mutex.new

    def console_notes : Array(String)
      ["Endpoint 1: Joint Fabric Administrator and Joint Fabric Datastore"]
    end

    # Applications can supply their own PAA and CD signer trust, together with
    # a revocation decision source. No test trust is installed by default.
    def migration_attestation_trust=(trust : Matter::Controller::AttestationTrustStore) : Nil
      if trust.paa_certificates.empty? || trust.cd_signers.empty? || !trust.revocation_check
        raise Matter::ConfigurationError.new("Migration trust requires PAA, CD signer, and revocation source")
      end
      @migration_attestation_trust = trust
    end

    private def migration_attestation_verifier : Matter::Controller::DeviceAttestationVerifier
      trust = @migration_attestation_trust || migration_test_attestation_trust
      raise Matter::ConfigurationError.new("Migration attestation trust is not configured") unless trust
      Matter::Controller::DeviceAttestationVerifier.new(trust)
    end

    private def migration_test_attestation_trust : Matter::Controller::AttestationTrustStore?
      return unless ENV["MATTER_JFA_MIGRATION_TEST_TRUST"]? == "1"
      fixture = Matter::Controller::AttestationTrustStore.matter_test_fixture
      paa_path = ENV["MATTER_JFA_MIGRATION_TEST_SDK_PAA"]?
      cd_dir = ENV["MATTER_JFA_MIGRATION_TEST_SDK_CD_DIR"]?
      return fixture unless paa_path && cd_dir

      signers = fixture.cd_signers.dup
      Dir.glob(File.join(cd_dir, "*.der")).each do |path|
        cert = OpenSSL::X509::Certificate.from_der(File.read(path).to_slice)
        ski = LibCrypto.x509_get0_subject_key_id(cert)
        next if ski.null?
        next unless LibCrypto.asn1_string_length(ski) == 20
        ski_bytes = Slice.new(LibCrypto.asn1_string_get0_data(ski), 20).dup
        signers[ski_bytes.hexstring.upcase] = cert.public_key.as(OpenSSL::PKey::EC).public_key_bytes
      end
      Matter::Controller::AttestationTrustStore.new(
        fixture.paa_certificates + [File.read(paa_path).to_slice.dup], signers,
        allow_test_attestation: true, revocation_check: fixture.revocation_check)
    end

    def commands : Array(Tuple(String, String))
      [{"transfer-anchor", "Transfer Anchor role from a joined fabric: transfer-anchor <old-anchor-node-id-hex>"},
       {"transfer-status", "Show the persisted Anchor transfer stage"},
       {"remove-administrator", "Remove a consented JFA: remove-administrator <node-id-hex>"}]
    end

    def handle_command(name : String, argument : String?) : Bool
      case name
      when "transfer-status"
        document = persistence.app_document(APP_TRANSFER_DOCUMENT)
        journal = document ? Matter::Controller::AnchorTransfer::Journal.from_document(document) : nil
        puts(journal ? "Anchor transfer: #{journal.stage} for node 0x#{journal.candidate_node_id.to_s(16)}" : "No Anchor transfer journal")
      when "transfer-anchor"
        unless argument && (old_node_id = argument.to_u64?(16))
          puts "Usage: transfer-anchor <old-anchor-node-id-hex>"
          return true
        end
        begin
          reject_fenced_mutation!
          transfer_anchor_from(old_node_id)
          puts "Anchor transfer completed"
        rescue ex : Matter::Error | IO::Error | ArgumentError
          ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Anchor transfer stopped" }
          puts "Anchor transfer stopped: #{ex.message}"
        end
      when "remove-administrator"
        unless argument && (outgoing_node_id = argument.to_u64?(16))
          puts "Usage: remove-administrator <node-id-hex>"
          return true
        end
        begin
          reject_fenced_mutation!
          remove_administrator(outgoing_node_id)
          puts "Administrator removal completed"
        rescue ex : Matter::Error | IO::Error | ArgumentError
          ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Administrator removal stopped" }
          puts "Administrator removal stopped: #{ex.message}"
        end
      else
        return false
      end
      true
    end

    protected def before_factory_reset : Nil
      reject_fenced_mutation!
    end

    protected def before_storage_recovery(storage : Matter::Storage::Backend) : Nil
      storage.open unless storage.open?
      if storage.read(Matter::Storage::Collections::APP, APP_PARTICIPANT_RECOVERY_FENCE) &&
         storage.read(Matter::Commissioning::CredentialJournal::COLLECTION,
           Matter::Commissioning::CredentialJournal::ID)
        raise Matter::StorageError.new("Participant recovery fence conflicts with a pending credential undo journal")
      end
    end

    protected def before_start : Nil
      super
      Matter::Controller::StateStore.new(persistence.backend).bind_transport_counter(message_handler.transport.message_counter)
      restore_participant_recovery_fence!
      install_participant_recovery_protocol_locks!
      reconcile_saved_fabric_bindings
      # The second endpoint is a retained bootstrap JFA only when explicitly
      # provisioned. A wildcard JCM read must not discover a second JFA with
      # a null AdministratorFabricIndex, which the SDK correctly rejects.
      remove_endpoint(BOOTSTRAP_JFA_ENDPOINT_ID, notify_subscribers: false) unless ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"]? == "1"
      connect_failsafe_lifecycle
      fabrics = fabric_table.all_fabrics
      fabrics.select { |fabric| compliant_anchor_fabric?(fabric) }.each { |fabric| attach_joint_fabric(fabric) }
      fabrics.reject { |fabric| compliant_anchor_fabric?(fabric) }.each { |fabric| attach_joined_fabric(fabric) }
      fabrics.each { |fabric| attach_unprovisioned_administrator(fabric) }
      install_participant_recovery_guards!
    end

    private def recovery_fenced? : Bool
      !!@participant_recovery_fence || @participant_recovery_fence_uncertain
    end

    private def reject_fenced_mutation! : Nil
      if recovery_fenced?
        raise Matter::ClusterError.new("Participant credential recovery is fenced",
          Matter::InteractionModel::StatusCode::Busy)
      end
    end

    private def restore_participant_recovery_fence! : Nil
      if document = persistence.app_document(APP_PARTICIPANT_RECOVERY_FENCE)
        fence = ParticipantRecoveryFence.from_document(document)
        validate_recovery_lease_id!(fence.lease_id)
        if !Matter::DataType::NodeId.valid_joint_fabric?(fence.anchor_node_id) ||
           !Matter::DataType::NodeId.valid_joint_fabric?(fence.participant_node_id) ||
           !Matter::DataType::NodeId.valid_joint_fabric?(fence.outgoing_node_id) ||
           fence.root_public_key.empty? || fence.credential.empty?
          raise Matter::StorageError.new("Invalid durable participant recovery fence")
        end
        @participant_recovery_fence = fence
      end
    end

    private def install_participant_recovery_protocol_locks! : Nil
      protocol_lock = @message_handler.registry.protocol_mutex
      general_commissioning.failsafe.protocol_lock = protocol_lock
      operational_credentials.credentials.protocol_lock = protocol_lock
      fabric_table.protocol_lock = protocol_lock
      @message_handler.clusters.values.each do |cluster|
        cluster.as?(Matter::Cluster::GroupKeyManagement).try(&.protocol_lock=(protocol_lock))
      end
    end

    private def install_participant_recovery_guards! : Nil
      @message_handler.clusters.values.each do |cluster|
        cluster.on_before_command = ->(command_id : UInt32) do
          # B must obtain a signed CASE challenge when recovering after a
          # restart. This command reads the installed NOC and signs the
          # challenge without changing credentials or fabric state.
          credentials = cluster.as?(Matter::Cluster::OperationalCredentials)
          permitted = credentials &&
                      command_id == Matter::Cluster::OperationalCredentials::CMD_SIGN_VID_VERIFICATION_REQUEST &&
                      credentials.request_is_case_session? && credentials.request_fabric_index
          reject_fenced_mutation! unless permitted
        end
        cluster.on_before_write = ->(_attribute_id : UInt32) { reject_fenced_mutation! }
        if keys = cluster.as?(Matter::Cluster::GroupKeyManagement)
          keys.on_before_key_set_change =
            ->(_fabric_index : UInt8, _key_set_id : UInt16) { reject_fenced_mutation! }
          keys.on_before_direct_mutation = -> { reject_fenced_mutation! }
        end
      end
      general_commissioning.failsafe.on_before_arm =
        ->(_seconds : UInt16, _fabric_index : UInt8?, _pase : Bool) { reject_fenced_mutation! }
      general_commissioning.failsafe.on_before_arm_timer =
        ->(_seconds : UInt16) { reject_fenced_mutation! }
      general_commissioning.failsafe.on_before_state_change = -> { reject_fenced_mutation! }
      operational_credentials.credentials.on_before_credential_change =
        ->(_mutation : Matter::Commissioning::CredentialService::CredentialMutation) { reject_fenced_mutation! }
      fabric_table.on_before_fabric_change =
        ->(_mutation : Matter::FabricTable::FabricMutation, _fabric_index : UInt8) { reject_fenced_mutation! }
      fabric_table.on_before_clear = -> { reject_fenced_mutation! }
    end

    protected def fabric_added(fabric : Matter::Fabric) : Nil
      attach_joint_fabric(fabric)
      attach_joined_fabric(fabric)
      attach_unprovisioned_administrator(fabric)
    end

    protected def fabric_removal_snapshot_clusters : Array(Matter::Cluster::Base)
      super + [joint_fabric_administrator, joint_fabric_datastore,
               bootstrap_joint_fabric_administrator, bootstrap_joint_fabric_datastore]
    end

    protected def fabric_removal_app_snapshot_keys : Array(String)
      [APP_FABRIC_BINDING_DOCUMENT, APP_BOOTSTRAP_BINDING_DOCUMENT]
    end

    protected def before_fabric_removed(fabric_index : UInt8) : Nil
      # Fence cluster access before the index becomes reusable, while keeping
      # the Datastore contents, binding, and credentials until the fabric
      # document is deleted. A failed deletion can reattach the same fabric
      # with its full Datastore; an orphan binding is cleared on startup if
      # the post-delete callback was interrupted.
      fabric = fabric_table.get_fabric(fabric_index) || return
      if bootstrap_joint_fabric_datastore.joint_fabric_index == fabric_index ||
         bootstrap_joint_fabric_administrator.administrator_fabric_index == fabric_index ||
         binding_index(APP_BOOTSTRAP_BINDING_DOCUMENT) == fabric_index
        persist_fabric_binding(fabric, APP_BOOTSTRAP_BINDING_DOCUMENT)
        @bootstrap_datastore_propagator.try(&.stop!)
        @bootstrap_datastore_propagator = nil
        bootstrap_joint_fabric_datastore.access_mode = Datastore::AccessMode::Inactive
        bootstrap_joint_fabric_datastore.joint_fabric_index = nil
        bootstrap_joint_fabric_datastore.allow_jcm_pase_group_list = nil
        bootstrap_joint_fabric_administrator.administrator_fabric_index = nil
        bootstrap_joint_fabric_administrator.service = nil
        unless persistence.save_cluster(bootstrap_joint_fabric_datastore)
          raise Matter::StorageError.new("Could not persist fenced bootstrap Joint Fabric Datastore")
        end
      end
      if joint_fabric_datastore.joint_fabric_index == fabric_index ||
         joint_fabric_administrator.administrator_fabric_index == fabric_index ||
         binding_index(APP_FABRIC_BINDING_DOCUMENT) == fabric_index
        persist_fabric_binding(fabric, APP_FABRIC_BINDING_DOCUMENT)
        @datastore_propagator.try(&.stop!)
        @datastore_propagator = nil
        joint_fabric_datastore.access_mode = Datastore::AccessMode::Inactive
        joint_fabric_datastore.joint_fabric_index = nil
        joint_fabric_datastore.allow_jcm_pase_group_list = nil
        joint_fabric_administrator.administrator_fabric_index = nil
        joint_fabric_administrator.service = nil
        unless persistence.save_cluster(joint_fabric_datastore)
          raise Matter::StorageError.new("Could not persist fenced Joint Fabric Datastore")
        end
      end
      unless persistence.save_cluster(joint_fabric_administrator) &&
             persistence.save_cluster(bootstrap_joint_fabric_administrator)
        raise Matter::StorageError.new("Could not persist erased Joint Fabric Administrator index")
      end
      persistence.flush
    end

    private def reconcile_saved_fabric_bindings : Nil
      {APP_FABRIC_BINDING_DOCUMENT, APP_BOOTSTRAP_BINDING_DOCUMENT}.each do |document_name|
        if document = persistence.app_document(document_name)
          binding = FabricBindingState.from_document(document)
          fabric = fabric_table.get_fabric(binding.fabric_index)
          unless fabric && binding.matches?(fabric)
            reject_binding_reconciliation_under_fence!
            fabric_removed(binding.fabric_index)
          end
        end
      end
      { {joint_fabric_administrator, joint_fabric_datastore, ANCHOR_JFA_ENDPOINT_ID,
         APP_FABRIC_BINDING_DOCUMENT, APP_BOOTSTRAP_BINDING_DOCUMENT, APP_ROLE_DOCUMENT, APP_ICAC_DOCUMENT},
       {bootstrap_joint_fabric_administrator, bootstrap_joint_fabric_datastore, BOOTSTRAP_JFA_ENDPOINT_ID,
        APP_BOOTSTRAP_BINDING_DOCUMENT, APP_FABRIC_BINDING_DOCUMENT, APP_BOOTSTRAP_ROLE_DOCUMENT, APP_BOOTSTRAP_ICAC_DOCUMENT} }.each do |administrator, datastore, endpoint_id, document_name, other_document_name, role_document, icac_document|
        next if persistence.app_document(document_name)

        persistence.delete_app_document(APP_TRANSFER_DOCUMENT) if endpoint_id == ANCHOR_JFA_ENDPOINT_ID

        # Legacy stores without an authenticated binding cannot distinguish a
        # new FabricID under the same root at a reused index. A partially
        # erased store may lack the JFA index while retaining JFD lists.
        if index = administrator.administrator_fabric_index
          reject_binding_reconciliation_under_fence!
          fabric_removed(index)
        elsif !datastore.anchor_root_ca.empty?
          reject_binding_reconciliation_under_fence!
          datastore.clear_fabric_state
          administrator.service = nil
          persistence.forget_cluster(endpoint_id, Datastore::CLUSTER_ID)
          persistence.delete_app_document(role_document)
          persistence.delete_app_document(icac_document)
          persistence.delete_app_document(APP_KEY_DOCUMENT) unless persistence.app_document(other_document_name)
        end
      end
    end

    private def reject_binding_reconciliation_under_fence! : Nil
      if recovery_fenced?
        raise Matter::StorageError.new("Participant recovery fence blocks destructive binding reconciliation")
      end
    end

    protected def started_commissioning_mode : Nil
      super
      # The official multi-ecosystem fixture starts this external DUT before
      # its first SDK test device. Keep it out of SDK on-network discovery
      # until that device has completed commissioning.
      @responder.stop_commissioning if ENV["MATTER_JFA_DISCOVERY_GATE_PATH"]?
    end

    protected def on_started : Nil
      super
      if gate = ENV["MATTER_JFA_DISCOVERY_GATE_PATH"]?
        discovery_enabled = false
        every(1.second) do
          if !discovery_enabled && File.exists?(gate) && @fabric_table.empty?
            discovery_enabled = true
            @lifecycle.sync_advertisements
          end
        end
      end
      @propagation_started = true
      @datastore_propagator.try(&.start) if joint_fabric_datastore.access_mode.active?
      @bootstrap_datastore_propagator.try(&.start) if bootstrap_joint_fabric_datastore.access_mode.active?
      if ENV["MATTER_JFA_JCM_REQUEST_PATH"]?
        every(1.second) { process_anchor_exchange_request }
      end
      if ENV["MATTER_JFA_COMMAND_PATH"]?
        every(1.second) { process_command_request }
      end
      every(5.seconds) { poll_new_anchor_subscription }
    end

    def shutdown! : Nil
      @watch_stopped = true
      close_new_anchor_subscription
      @datastore_propagator.try(&.stop!)
      @bootstrap_datastore_propagator.try(&.stop!)
      super
    end

    protected def fabric_removed(fabric_index : UInt8) : Nil
      if @unprovisioned_service_fabric_index == fabric_index
        joint_fabric_administrator.service = nil
        @unprovisioned_service_fabric_index = nil
      end
      if bootstrap_joint_fabric_datastore.joint_fabric_index == fabric_index ||
         bootstrap_joint_fabric_administrator.administrator_fabric_index == fabric_index ||
         binding_index(APP_BOOTSTRAP_BINDING_DOCUMENT) == fabric_index
        @bootstrap_datastore_propagator.try(&.stop!)
        @bootstrap_datastore_propagator = nil
        bootstrap_joint_fabric_datastore.clear_fabric_state
        bootstrap_joint_fabric_datastore.allow_jcm_pase_group_list = nil
        bootstrap_joint_fabric_administrator.administrator_fabric_index = nil
        bootstrap_joint_fabric_administrator.service = nil
        persistence.forget_cluster(BOOTSTRAP_JFA_ENDPOINT_ID, Datastore::CLUSTER_ID)
        persistence.delete_app_document(APP_BOOTSTRAP_ROLE_DOCUMENT)
        persistence.delete_app_document(APP_BOOTSTRAP_ICAC_DOCUMENT)
        persistence.delete_app_document(APP_BOOTSTRAP_TRANSFER_WATCH_DOCUMENT)
        persistence.delete_app_document(APP_KEY_DOCUMENT) unless joint_fabric_datastore.joint_fabric_index
        persistence.delete_app_document(APP_BOOTSTRAP_BINDING_DOCUMENT)
        if propagation = @propagation_fabric
          if propagation.fabric_index == fabric_index && joint_fabric_datastore.joint_fabric_index != fabric_index
            if store = @controller_store
              state = store.load
              state.remove_fabric(propagation.fabric_id, propagation.root_public_key, propagation.node_id)
              store.save(state)
            end
            @propagation_fabric = nil
            @controller_store = nil
          end
        end
      end
      @participant_view_current = false
      close_new_anchor_subscription
      if joint_fabric_datastore.joint_fabric_index == fabric_index ||
         joint_fabric_administrator.administrator_fabric_index == fabric_index ||
         binding_index(APP_FABRIC_BINDING_DOCUMENT) == fabric_index
        @datastore_propagator.try(&.stop!)
        @datastore_propagator = nil
        if fabric = @propagation_fabric
          if fabric.fabric_index == fabric_index
            if store = @controller_store
              state = store.load
              state.remove_fabric(fabric.fabric_id, fabric.root_public_key, fabric.node_id)
              store.save(state)
            end
          end
        end
        if @propagation_fabric.try(&.fabric_index) == fabric_index
          @propagation_fabric = nil
          @controller_store = nil
        end
        joint_fabric_datastore.clear_fabric_state
        joint_fabric_datastore.allow_jcm_pase_group_list = nil
        @jcm_failsafe_session_id = nil
        persistence.forget_cluster(ANCHOR_JFA_ENDPOINT_ID, Datastore::CLUSTER_ID)
        joint_fabric_administrator.administrator_fabric_index = nil
        joint_fabric_administrator.service = nil
        @joint_fabric_provisioned = !bootstrap_joint_fabric_datastore.joint_fabric_index.nil?
        @anchor_role = false
        persistence.delete_app_document(APP_ROLE_DOCUMENT)
        persistence.delete_app_document(APP_ICAC_DOCUMENT)
        persistence.delete_app_document(APP_TRANSFER_DOCUMENT)
        persistence.delete_app_document(APP_KEY_DOCUMENT) unless bootstrap_joint_fabric_datastore.joint_fabric_index
        persistence.delete_app_document(APP_FABRIC_BINDING_DOCUMENT)
      end
      unless persistence.save_cluster(joint_fabric_administrator) &&
             persistence.save_cluster(bootstrap_joint_fabric_administrator)
        raise Matter::StorageError.new("Could not persist erased Joint Fabric Administrator index")
      end
    end

    private def binding_index(document_name : String) : UInt8?
      document = persistence.app_document(document_name)
      document ? FabricBindingState.from_document(document).fabric_index : nil
    end

    private def persist_fabric_binding(fabric : Matter::Fabric, document_name : String) : Nil
      persistence.write_app_document(document_name,
        FabricBindingState.new(fabric.fabric_index, fabric.fabric_id, fabric.root_public_key).to_document)
    end

    protected def commissioning_info_for(mode : Matter::MDNS::CommissioningMode) : Matter::MDNS::CommissioningInfo
      info = super
      bootstrap_active = bootstrap_joint_fabric_datastore.access_mode.active? &&
                         (bootstrap_joint_fabric_datastore.joint_fabric_index != joint_fabric_datastore.joint_fabric_index ||
                          joint_fabric_datastore.status.state != Datastore::DatastoreStateEnum::DeletePending)
      info.joint_fabric_role = if joint_fabric_datastore.status.state == Datastore::DatastoreStateEnum::DeletePending &&
                                  !bootstrap_active
                                 nil
                               elsif !@joint_fabric_provisioned
                                 Matter::MDNS::JointFabricRole::Available
                               elsif @anchor_role || bootstrap_active
                                 Matter::MDNS::JointFabricRole::Administrator |
                                   Matter::MDNS::JointFabricRole::Anchor |
                                   Matter::MDNS::JointFabricRole::Datastore
                               else
                                 Matter::MDNS::JointFabricRole::Administrator
                               end
      info
    end

    # A freshly commissioned JFA has no Anchor role yet, but its JFA commands
    # still have defined fail-safe and validation results. Keep an isolated
    # service on that fabric until the device joins or provisions a Joint Fabric.
    private def attach_unprovisioned_administrator(fabric : Matter::Fabric) : Nil
      return if joint_fabric_administrator.service
      root = fabric.root_cert || return
      administrator = joint_fabric_administrator
      administrator.service = Matter::Commissioning::JointFabricAdministratorService.new(
        icac_private_key: Matter::Crypto::StandardCrypto.new.create_key_pair,
        root_certificate: root,
        fabric_id: fabric.fabric_id,
        failsafe_armed: -> { general_commissioning.failsafe_armed? },
        vendor_id_verified: ->(_index : UInt8) { false },
        open_window: ->(_request : Admin::OpenJointCommissioningWindowRequest) { Matter::InteractionModel::Status.invalid_command },
        transfer_authorized: ->(_node_id : UInt64) { false },
        datastore_busy: -> { false },
        begin_transfer: -> { nil },
        complete_transfer: -> { nil })
      @unprovisioned_service_fabric_index = fabric.fabric_index
    end

    private def attach_joint_fabric(fabric : Matter::Fabric) : Nil
      root = fabric.root_cert
      unless root
        ::Log.for("matter.example.joint_fabric_administrator").info { "JFA activation skipped: fabric has no root certificate" }
        return
      end
      unless compliant_anchor_fabric?(fabric)
        ::Log.for("matter.example.joint_fabric_administrator").info do
          "JFA activation skipped: Anchor CAT or ICAC validation failed (fabric_id=0x#{fabric.fabric_id.to_s(16)}, cats=#{fabric.cats.map(&.value).map(&.to_s(16))})"
        end
        return
      end
      icac = fabric.intermediate_cert
      unless icac
        ::Log.for("matter.example.joint_fabric_administrator").info { "JFA activation skipped: no Anchor ICAC" }
        return
      end
      remote_csr_path = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
      key = remote_csr_path ? nil : provisioned_icac_key(fabric, icac)
      unless key || remote_csr_path
        ::Log.for("matter.example.joint_fabric_administrator").warn do
          "JFA activation skipped: Anchor ICAC private key unavailable or mismatched (fabric_id=0x#{fabric.fabric_id.to_s(16)})"
        end
        return
      end
      if document = persistence.app_document(APP_FABRIC_BINDING_DOCUMENT)
        binding = FabricBindingState.from_document(document)
        unless binding.matches?(fabric)
          if installed = fabric_table.get_fabric(binding.fabric_index)
            if binding.matches?(installed)
              configure_bootstrap_datastore(fabric, root, icac, key)
              return
            end
          end
          fabric_removed(binding.fabric_index)
        end
      end

      ::Log.for("matter.example.joint_fabric_administrator").info do
        "JFA Anchor activated (fabric_id=0x#{fabric.fabric_id.to_s(16)}, index=#{fabric.fabric_index})"
      end

      grant_administrator_cat_access(fabric)
      @joint_fabric_provisioned = true
      @anchor_role = persisted_anchor_role

      datastore = joint_fabric_datastore
      datastore.joint_fabric_index = fabric.fabric_index
      datastore.access_mode = if @anchor_role
                                Datastore::AccessMode::Active
                              elsif datastore.status.state.delete_pending? && !persisted_transfer_complete?
                                Datastore::AccessMode::Frozen
                              else
                                Datastore::AccessMode::Inactive
                              end
      configure_jcm_pase_group_list(datastore)
      unless datastore.status.state == Datastore::DatastoreStateEnum::DeletePending
        # Older Anchor stores may contain a zero key set without its IPK.
        # Persist the repaired key before this JFA serves the Datastore: a
        # debounced write alone can be lost on a process crash.
        stored_ipk = datastore.group_key_set_list.find do |entry|
          entry.group_key_set_id == ANCHOR_IPK_KEY_SET_ID
        end.try(&.epoch_key0)
        ipk_needs_repair = stored_ipk.nil?
        attach_anchor_ipk_key_set(datastore, fabric)
        status = datastore.configure_anchor(root, fabric.node_id, fabric.vendor_id,
          anchor_friendly_name_for_attachment(datastore, fabric, root),
          ipk_needs_repair ? fabric.ipk : nil)
        sync_anchor_group_key_set(datastore, fabric)
        if ipk_needs_repair
          raise Matter::StorageError.new("Could not repair Anchor Datastore IPK") unless status.success?
          unless persistence.save_cluster(datastore)
            raise Matter::StorageError.new("Could not persist repaired Anchor Datastore IPK")
          end
        end
        seed_joint_fabric_groups(datastore)
        seed_anchor_administrator(datastore, fabric, icac)
      end

      administrator = joint_fabric_administrator
      administrator.administrator_fabric_index = fabric.fabric_index
      remote_csr_provider = remote_csr_path.try do |path|
        Matter::Commissioning::RemoteIcacCsrProvider.new(path, fabric.fabric_id, fabric.root_public_key)
      end
      administrator.service = Matter::Commissioning::JointFabricAdministratorService.new(
        icac_private_key: key,
        root_certificate: root,
        fabric_id: fabric.fabric_id,
        failsafe_armed: -> { general_commissioning.failsafe_armed? },
        vendor_id_verified: ->(_index : UInt8) { true },
        open_window: ->(request : Admin::OpenJointCommissioningWindowRequest) { open_joint_window(request, fabric) },
        transfer_authorized: ->(_node_id : UInt64) { ENV["MATTER_JFA_ALLOW_TRANSFER"]? == "1" },
        datastore_busy: -> { joint_fabric_datastore.transfer_busy? },
        begin_transfer: -> { begin_anchor_transfer },
        complete_transfer: -> {
          persist_anchor_role(false, transfer_complete: true)
          if bootstrap_joint_fabric_datastore.joint_fabric_index == fabric.fabric_index
            persist_bootstrap_anchor_role(false, transfer_complete: true)
          end
          persistence.flush
          lifecycle.sync_advertisements
          nil
        },
        on_transfer_requested: ->(node_id : UInt64, index : UInt8) { record_transfer_candidate(node_id, index) },
        initial_transfer_requester: persisted_transfer_requester(fabric, datastore),
        initial_icac: persisted_icac,
        persist_icac: ->(certificate : Bytes?) { persist_icac(certificate, APP_ICAC_DOCUMENT, administrator) },
        verify_anchor_initiator: ->(node_id : UInt64, index : UInt8, source : Socket::IPAddress, endpoint : UInt16) {
          verify_anchor_initiator(node_id, index, source, endpoint)
        },
        resolve_accessing_fabric: ->(index : UInt8) { accessing_fabric_identity(index) },
        existing_icac_certificate: icac,
        icac_csr_provider: remote_csr_provider,
        failsafe_fabric_matches: ->(index : UInt8?) {
          if context = general_commissioning.failsafe_context
            context.armed? && !index.nil? &&
            (context.associated_fabric_index == index ||
             (context.associated_fabric_index.nil? && context.added_fabric_index == index))
          else
            false
          end
        }
      )
      @unprovisioned_service_fabric_index = nil
      configure_propagator(fabric, root)
      configure_bootstrap_datastore(fabric, root, icac, key)
      persist_fabric_binding(fabric, APP_FABRIC_BINDING_DOCUMENT)
    end

    private def configure_bootstrap_datastore(fabric : Matter::Fabric, root : Bytes, icac : Bytes,
                                              key : Matter::Crypto::Key?) : Nil
      return unless ENV["MATTER_JFA_KEEP_BOOTSTRAP_DATASTORE"]? == "1"
      bootstrap = begin
        provisioned_anchor_bootstrap(fabric).fabric
      rescue Matter::ConfigurationError
        return
      end
      return unless bootstrap.fabric_id == fabric.fabric_id &&
                    bootstrap.root_public_key == fabric.root_public_key

      datastore = bootstrap_joint_fabric_datastore
      administrator = bootstrap_joint_fabric_administrator
      administrator.administrator_fabric_index = fabric.fabric_index
      remote_csr_provider = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?.try do |path|
        Matter::Commissioning::RemoteIcacCsrProvider.new(path, fabric.fabric_id, fabric.root_public_key)
      end
      datastore.joint_fabric_index = fabric.fabric_index
      role = bootstrap_role_state
      datastore.access_mode = if role.anchor?
                                Datastore::AccessMode::Active
                              elsif role.transfer_complete?
                                Datastore::AccessMode::Inactive
                              else
                                Datastore::AccessMode::Frozen
                              end
      configure_jcm_pase_group_list(datastore)
      stored_ipk = datastore.group_key_set_list.find(&.group_key_set_id.==(ANCHOR_IPK_KEY_SET_ID)).try(&.epoch_key0)
      attach_anchor_ipk_key_set(datastore, fabric)
      datastore.configure_anchor(root, fabric.node_id, fabric.vendor_id, "Bootstrap Anchor",
        stored_ipk.nil? ? fabric.ipk : nil)
      sync_anchor_group_key_set(datastore, fabric)
      seed_joint_fabric_groups(datastore)
      seed_anchor_administrator(datastore, fabric, icac)
      administrator.service = Matter::Commissioning::JointFabricAdministratorService.new(
        icac_private_key: key,
        root_certificate: root,
        fabric_id: fabric.fabric_id,
        failsafe_armed: -> { general_commissioning.failsafe_armed? },
        vendor_id_verified: ->(_index : UInt8) { true },
        open_window: ->(request : Admin::OpenJointCommissioningWindowRequest) {
          open_bootstrap_joint_window(request, fabric)
        },
        transfer_authorized: ->(_node_id : UInt64) { ENV["MATTER_JFA_ALLOW_TRANSFER"]? == "1" },
        datastore_busy: -> { datastore.transfer_busy? },
        begin_transfer: -> { begin_bootstrap_anchor_transfer },
        complete_transfer: -> {
          persist_bootstrap_anchor_role(false, transfer_complete: true)
          if joint_fabric_datastore.joint_fabric_index == fabric.fabric_index
            persist_anchor_role(false, transfer_complete: true)
          end
          persistence.flush
          lifecycle.sync_advertisements
          nil
        },
        on_transfer_requested: ->(node_id : UInt64, index : UInt8) {
          record_bootstrap_transfer_candidate(node_id, index)
        },
        initial_transfer_requester: persisted_transfer_requester(fabric, datastore,
          APP_BOOTSTRAP_TRANSFER_WATCH_DOCUMENT),
        initial_icac: persisted_icac(APP_BOOTSTRAP_ICAC_DOCUMENT),
        persist_icac: ->(certificate : Bytes?) { persist_bootstrap_icac(certificate, administrator, datastore) },
        verify_anchor_initiator: ->(node_id : UInt64, index : UInt8, source : Socket::IPAddress, endpoint : UInt16) {
          verify_anchor_initiator(node_id, index, source, endpoint)
        },
        resolve_accessing_fabric: ->(index : UInt8) { accessing_fabric_identity(index) },
        existing_icac_certificate: icac,
        icac_csr_provider: remote_csr_provider,
        failsafe_fabric_matches: ->(index : UInt8?) {
          if context = general_commissioning.failsafe_context
            context.armed? && !index.nil? &&
            (context.associated_fabric_index == index ||
             (context.associated_fabric_index.nil? && context.added_fabric_index == index))
          else
            false
          end
        }
      )
      if role.transfer_complete?
        administrator.administrator_fabric_index = nil
        administrator.service = nil
      end
      unless persistence.save_cluster(datastore)
        raise Matter::StorageError.new("Could not persist bootstrap Joint Fabric Datastore")
      end
      persist_fabric_binding(fabric, APP_BOOTSTRAP_BINDING_DOCUMENT)
      @bootstrap_datastore_propagator.try(&.stop!)
      store = @controller_store || Matter::Controller::StateStore.new(persistence.backend)
      delivery = Matter::Controller::DatastorePropagator::NetworkDelivery.new(
        store,
        fabric_id: fabric.fabric_id,
        root_public_key: fabric.root_public_key,
        controller_node_id: fabric.node_id,
        peer_hints: configured_peer_hints,
        shared_message_counter: message_handler.transport.message_counter
      )
      @bootstrap_datastore_propagator = Matter::Controller::DatastorePropagator.new(datastore, delivery)
      @controller_store = store
      @propagation_fabric = fabric
      @bootstrap_datastore_propagator.try(&.start) if @propagation_started
    end

    private def configure_jcm_pase_group_list(datastore : Datastore) : Nil
      datastore.allow_jcm_pase_group_list = -> {
        owner = @jcm_failsafe_session_id
        !owner.nil? && owner == datastore.request_session_id &&
        general_commissioning.failsafe_armed? &&
        administrator_commissioning.window.joint_window? &&
        administrator_commissioning.window_open?
      }
    end

    # JCM leaves the bootstrap fabric in place. Its JFA stays on endpoint 2,
    # while endpoint 1 follows the committed cross-signed ICAC onto the joined
    # fabric. Match both fabric identity and certificate before rebinding.
    private def attach_joined_fabric(fabric : Matter::Fabric) : Nil
      # A promoted Anchor may still retain the former Anchor fabric for its
      # controller journal. Its persisted Anchor role owns endpoint 1 now;
      # loading that residual joined fabric must not replace the copied store.
      if document = persistence.app_document(APP_ROLE_DOCUMENT)
        if JointFabricRoleState.from_document(document).anchor? &&
           joint_fabric_datastore.joint_fabric_index != fabric.fabric_index
          return
        end
      end
      certificate = persisted_icac
      unless certificate && joined_icac_matches_fabric?(certificate, fabric)
        ::Log.for("matter.example.joint_fabric_administrator").info do
          "Joined JFA activation skipped: committed ICAC #{certificate ? "mismatches" : "absent for"} fabric 0x#{fabric.fabric_id.to_s(16)}"
        end
        return
      end
      return if compliant_anchor_fabric?(fabric)
      root = fabric.root_cert || raise Matter::ConfigurationError.new("Joined Joint Fabric root is unavailable")
      remote_csr_provider = ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?.try do |path|
        Matter::Commissioning::RemoteIcacCsrProvider.new(path, fabric.fabric_id, fabric.root_public_key)
      end
      key = remote_csr_provider ? nil : provisioned_icac_key(fabric, certificate)
      unless key || remote_csr_provider
        raise Matter::ConfigurationError.new("Joined JFA ICAC private key is unavailable")
      end
      return if joint_fabric_datastore.joint_fabric_index == fabric.fabric_index &&
                joint_fabric_administrator.administrator_fabric_index == fabric.fabric_index &&
                joint_fabric_service.try(&.cross_signed_icac) == certificate

      grant_administrator_cat_access(fabric)
      unless persistence.app_document(APP_ROLE_DOCUMENT)
        persistence.write_app_document(APP_ROLE_DOCUMENT, JointFabricRoleState.new(false).to_document)
      end
      @anchor_role = persisted_anchor_role
      @joint_fabric_provisioned = true
      datastore = joint_fabric_datastore
      @datastore_propagator.try(&.stop!)
      @datastore_propagator = nil
      if datastore.joint_fabric_index != fabric.fabric_index
        # The fabric index is runtime-only. On restart, retain a copied store
        # only when its saved binding and root still identify this exact fabric.
        saved_binding_matches = if document = persistence.app_document(APP_FABRIC_BINDING_DOCUMENT)
                                  FabricBindingState.from_document(document).matches?(fabric)
                                else
                                  false
                                end
        restored_store_matches = datastore.joint_fabric_index.nil? &&
                                 datastore.anchor_root_ca == root && saved_binding_matches
        datastore.clear_fabric_state unless restored_store_matches
      end
      datastore.joint_fabric_index = fabric.fabric_index
      datastore.access_mode = @anchor_role ? Datastore::AccessMode::Active : Datastore::AccessMode::Inactive
      administrator = joint_fabric_administrator
      administrator.administrator_fabric_index = fabric.fabric_index
      administrator.service = Matter::Commissioning::JointFabricAdministratorService.new(
        icac_private_key: key,
        root_certificate: root,
        fabric_id: fabric.fabric_id,
        failsafe_armed: -> { general_commissioning.failsafe_armed? },
        vendor_id_verified: ->(_index : UInt8) { true },
        open_window: ->(request : Admin::OpenJointCommissioningWindowRequest) { open_joint_window(request, fabric) },
        transfer_authorized: ->(_node_id : UInt64) { ENV["MATTER_JFA_ALLOW_TRANSFER"]? == "1" },
        datastore_busy: -> { datastore.transfer_busy? },
        begin_transfer: -> { begin_anchor_transfer },
        complete_transfer: -> { persist_anchor_role(false, transfer_complete: true); persistence.flush; lifecycle.sync_advertisements; nil },
        on_transfer_requested: ->(node_id : UInt64, index : UInt8) { record_transfer_candidate(node_id, index) },
        initial_transfer_requester: persisted_transfer_requester(fabric, datastore),
        initial_icac: certificate,
        persist_icac: ->(value : Bytes?) { persist_icac(value, APP_ICAC_DOCUMENT, administrator) },
        verify_anchor_initiator: ->(node_id : UInt64, index : UInt8, source : Socket::IPAddress, endpoint : UInt16) {
          verify_anchor_initiator(node_id, index, source, endpoint)
        },
        resolve_accessing_fabric: ->(index : UInt8) { accessing_fabric_identity(index) },
        existing_icac_certificate: certificate,
        icac_csr_provider: remote_csr_provider,
        failsafe_fabric_matches: ->(index : UInt8?) {
          if context = general_commissioning.failsafe_context
            context.armed? && !index.nil? &&
            (context.associated_fabric_index == index ||
             (context.associated_fabric_index.nil? && context.added_fabric_index == index))
          else
            false
          end
        }
      )
      @unprovisioned_service_fabric_index = nil
      unless persistence.save_cluster(administrator) && persistence.save_cluster(datastore)
        raise Matter::StorageError.new("Could not persist joined Joint Fabric Administrator endpoints")
      end
      persist_fabric_binding(fabric, APP_FABRIC_BINDING_DOCUMENT)
      persistence.flush
    end

    # The operational NOC chains through the Anchor ICAC, while the JFA's
    # committed cross-signed ICAC certifies the JFA signing key. A local JFA
    # proves possession with its private key; an SDK-owned JFA delegates CSR
    # signing to its authenticated remote provider and retains the operational
    # ICAC public key while allowing the cross-signer a distinct ICAC ID.
    private def joined_icac_matches_fabric?(certificate : Bytes, fabric : Matter::Fabric) : Bool
      installed = fabric.intermediate_cert || return false
      root = fabric.root_cert || return false
      committed_icac = Matter::Crypto::MatterCertificate.from_slice(certificate)
      installed_icac = Matter::Crypto::MatterCertificate.from_slice(installed)
      remote_signer = !!ENV["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"]?
      expected_identity = remote_signer ? committed_icac.ec_public_key == installed_icac.ec_public_key : committed_icac.subject.icac_id == installed_icac.subject.icac_id
      unless committed_icac.subject.fabric_id == fabric.fabric_id &&
             committed_icac.subject.icac_id && expected_identity
        ::Log.for("matter.example.joint_fabric_administrator").info { "Joined JFA committed and installed ICAC identities differ" }
        return false
      end
      Matter::Crypto::MatterCertificate::Validation.verify_intermediate_profile(certificate, fabric.fabric_id)
      Matter::Crypto::MatterCertificate::Validation.verify_issued_by(certificate, root)
      Matter::Crypto::MatterCertificate::Validation.verify_signature(certificate, fabric.root_public_key)
      true
    rescue error : Matter::Error
      ::Log.for("matter.example.joint_fabric_administrator").info(exception: error) { "Joined JFA committed ICAC validation failed" }
      false
    end

    private def grant_administrator_cat_access(fabric : Matter::Fabric) : Nil
      acl = access_control
      version = fabric.cats.find(&.identity_value.==(ADMINISTRATOR_CAT_ID)).try(&.version) || 1_u16
      subject = Matter::DataType::NodeId.from_case_authenticated_tag(
        Matter::DataType::CaseAuthenticatedTag.create(ADMINISTRATOR_CAT_ID, version)).id
      return if acl.get_acl_for_fabric(fabric.fabric_index).any? do |entry|
                  subjects = entry.subjects
                  subjects.nil? || subjects.empty? || subjects.includes?(subject)
                end

      entries = acl.acl.dup
      entries << Matter::Cluster::AccessControl::AccessControlEntry.new(
        Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        [subject], nil, fabric.fabric_index)
      previous_context = acl.request_fabric_index
      begin
        acl.request_fabric_index = nil
        acl.acl = entries
      ensure
        acl.request_fabric_index = previous_context
      end
      unless persistence.save_cluster(acl)
        raise Matter::StorageError.new("Could not persist Joint Fabric Administrator CAT ACL")
      end
    end

    private def configure_propagator(fabric : Matter::Fabric, root : Bytes) : Nil
      @datastore_propagator.try(&.stop!)
      store = Matter::Controller::StateStore.new(persistence.backend)
      state = store.load
      existing = state.fabrics.find do |candidate|
        candidate.fabric_id == fabric.fabric_id &&
          candidate.root_public_key == fabric.root_public_key &&
          candidate.controller_node_id == fabric.node_id
      end
      bootstrap_info = if (path = ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"]?) && File.exists?(path)
                         begin
                           provisioned_anchor_bootstrap(fabric).fabric
                         rescue Matter::ConfigurationError
                           existing
                         end
                       else
                         existing
                       end
      if existing && (existing.controller_noc != fabric.operational_cert ||
         existing.controller_private_key != fabric.operational_private_key ||
         existing.ipk_epoch_keys != fabric.ipk_epoch_keys || existing.intermediate_cert != fabric.intermediate_cert ||
         existing.root_private_key != bootstrap_info.try(&.root_private_key) ||
         existing.intermediate_private_key != bootstrap_info.try(&.intermediate_private_key))
        state.remove_fabric(fabric.fabric_id, fabric.root_public_key, fabric.node_id)
        existing = nil
      end
      unless existing
        state.install_fabric(Matter::Controller::FabricInfo.new(
          fabric_id: fabric.fabric_id,
          controller_node_id: fabric.node_id,
          ipk_value: fabric.ipk,
          root_cert: root,
          root_public_key: fabric.root_public_key,
          controller_noc: fabric.operational_cert,
          controller_private_key: fabric.operational_private_key,
          root_private_key: bootstrap_info.try(&.root_private_key),
          admin_vendor_id: fabric.vendor_id,
          intermediate_cert: fabric.intermediate_cert,
          intermediate_private_key: bootstrap_info.try(&.intermediate_private_key),
          ipk_epoch_keys: fabric.ipk_epoch_keys
        ))
        store.save(state)
      end
      delivery = Matter::Controller::DatastorePropagator::NetworkDelivery.new(
        store,
        fabric_id: fabric.fabric_id,
        root_public_key: fabric.root_public_key,
        controller_node_id: fabric.node_id,
        peer_hints: configured_peer_hints,
        shared_message_counter: message_handler.transport.message_counter
      )
      @datastore_propagator = Matter::Controller::DatastorePropagator.new(joint_fabric_datastore, delivery)
      @controller_store = store
      @propagation_fabric = fabric
      @datastore_propagator.try(&.start) if @propagation_started && joint_fabric_datastore.access_mode.active?
    end

    private def seed_joint_fabric_groups(datastore : Datastore) : Nil
      unless datastore.group_list.any?(&.group_cat.==(ADMINISTRATOR_CAT_ID))
        datastore.seed_reserved_cat_group(ADMIN_GROUP_ID, "Administrators", ADMINISTRATOR_CAT_ID, Datastore::FIRST_GROUP_CAT_VERSION)
      end
      unless datastore.group_list.any?(&.group_cat.==(ANCHOR_CAT_ID))
        datastore.seed_reserved_cat_group(ANCHOR_GROUP_ID, "Anchors", ANCHOR_CAT_ID, Datastore::FIRST_GROUP_CAT_VERSION)
      end
    end

    private def anchor_friendly_name_for_attachment(datastore : Datastore, fabric : Matter::Fabric,
                                                    root : Bytes) : String
      binding_document = persistence.app_document(APP_FABRIC_BINDING_DOCUMENT)
      if binding_document && datastore.status.state.committed? &&
         datastore.anchor_root_ca == root && datastore.anchor_node_id == fabric.node_id &&
         !datastore.friendly_name.empty? &&
         FabricBindingState.from_document(binding_document).matches?(fabric)
        return datastore.friendly_name
      end
      DEFAULT_ANCHOR_FRIENDLY_NAME
    end

    private def seed_anchor_administrator(datastore : Datastore, fabric : Matter::Fabric, icac : Bytes) : Nil
      return if datastore.admin_list.any?(&.node_id.==(fabric.node_id))
      datastore.add_admin(Datastore::AddAdminRequest.new(
        fabric.node_id, DEFAULT_ANCHOR_FRIENDLY_NAME, fabric.vendor_id, icac))
    end

    private def anchor_ipk_epoch_keys(entry : Datastore::DatastoreGroupKeySetStruct) : Array(Bytes)
      [entry.epoch_key0, entry.epoch_key1, entry.epoch_key2].compact
    end

    private def anchor_group_key_set(entry : Datastore::DatastoreGroupKeySetStruct) : Matter::Cluster::GroupKeyManagement::GroupKeySetStruct
      Matter::Cluster::GroupKeyManagement::GroupKeySetStruct.new(ANCHOR_IPK_KEY_SET_ID,
        epoch_key0: entry.epoch_key0, epoch_start_time0: entry.epoch_start_time0,
        epoch_key1: entry.epoch_key1, epoch_start_time1: entry.epoch_start_time1,
        epoch_key2: entry.epoch_key2, epoch_start_time2: entry.epoch_start_time2)
    end

    private def sync_anchor_group_key_set(datastore : Datastore, fabric : Matter::Fabric) : Nil
      entry = datastore.group_key_set_list.find(&.group_key_set_id.==(ANCHOR_IPK_KEY_SET_ID))
      return unless entry && entry.epoch_key0
      group_keys = @node.get_cluster!(Matter::Cluster::GroupKeyManagement)
      desired = anchor_group_key_set(entry)
      return if group_keys.get_key_set(ANCHOR_IPK_KEY_SET_ID, fabric.fabric_index) == desired
      group_keys.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(desired),
        fabric.fabric_index, allow_zero_ipk_start_time: true)
    end

    private def attach_anchor_ipk_key_set(datastore : Datastore, fabric : Matter::Fabric) : Nil
      if stored = datastore.group_key_set_list.find(&.group_key_set_id.==(ANCHOR_IPK_KEY_SET_ID))
        keys = anchor_ipk_epoch_keys(stored)
        unless keys.empty? || fabric.ipk_epoch_keys == keys
          fabric.ipk_epoch_keys = keys
          raise Matter::StorageError.new("Could not restore Anchor CASE IPK epochs") unless fabric_table.update_fabric(fabric)
        end
      end

      datastore.on_ipk_key_set_updated = ->(cluster : Datastore, entry : Datastore::DatastoreGroupKeySetStruct) do
        previous = fabric.ipk_epoch_keys.map(&.dup)
        group_keys = @node.get_cluster!(Matter::Cluster::GroupKeyManagement)
        previous_group_key_set = group_keys.get_key_set(ANCHOR_IPK_KEY_SET_ID, fabric.fabric_index)
        previous_group_version = group_keys.data_version
        begin
          persistence.backend.transaction do
            raise Matter::StorageError.new("Could not persist Anchor Datastore IPK") unless persistence.save_cluster(cluster)
            controller_store = Matter::Controller::StateStore.new(persistence.backend)
            controller_state = controller_store.load
            identity = controller_state.fabric_for(fabric.fabric_id, fabric.root_public_key, fabric.node_id)
            identity.ipk_epoch_keys = [entry.epoch_key0, entry.epoch_key1, entry.epoch_key2].compact
            controller_state.replace_fabric(identity)
            controller_store.save(controller_state)
            desired = anchor_group_key_set(entry)
            group_keys.handle_key_set_write(Matter::Cluster::GroupKeyManagement::KeySetWriteRequest.new(desired),
              fabric.fabric_index, allow_zero_ipk_start_time: true, notify_version_change: false)
          end
        rescue ex
          fabric.ipk_epoch_keys = previous
          group_keys.restore_ipk_key_set_after_failed_write(fabric.fabric_index, previous_group_key_set,
            previous_group_version)
          raise ex
        end
        begin
          group_keys.notify_persisted_ipk_key_set_write
        rescue ex
          ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) do
            "Could not notify subscribers of persisted Anchor IPK update"
          end
        end
      end
    end

    private def connect_failsafe_lifecycle : Nil
      self.commissioning_commit_write = ->(_backend : Matter::Storage::Backend) do
        joint_fabric_service.try(&.write_pending_completion)
        bootstrap_joint_fabric_service.try(&.write_pending_completion)
      end
      self.commissioning_commit_complete = -> do
        joint_fabric_service.try(&.confirm_pending_completion)
        bootstrap_joint_fabric_service.try(&.confirm_pending_completion)
      end
      armed = general_commissioning.on_failsafe_armed
      expired = general_commissioning.on_failsafe_expired
      succeeded = general_commissioning.on_failsafe_success
      general_commissioning.on_failsafe_armed = -> do
        armed.try(&.call)
        if administrator_commissioning.window.joint_window? && !general_commissioning.request_is_case_session?
          @jcm_failsafe_session_id = general_commissioning.request_session_id
        end
        joint_fabric_service.try(&.reset_failsafe)
        bootstrap_joint_fabric_service.try(&.reset_failsafe)
      end
      general_commissioning.on_failsafe_expired = -> do
        expired.try(&.call)
        @jcm_failsafe_session_id = nil
        joint_fabric_service.try(&.on_failsafe_expired)
        bootstrap_joint_fabric_service.try(&.on_failsafe_expired)
      end
      general_commissioning.on_failsafe_success = -> do
        succeeded.try(&.call)
        @jcm_failsafe_session_id = nil
        fabric_table.all_fabrics.each { |fabric| attach_joined_fabric(fabric) }
        restore_bootstrap_administrator_binding
      end
    end

    private def joint_fabric_service : Matter::Commissioning::JointFabricAdministratorService?
      joint_fabric_administrator.service.as?(Matter::Commissioning::JointFabricAdministratorService)
    end

    private def bootstrap_joint_fabric_service : Matter::Commissioning::JointFabricAdministratorService?
      bootstrap_joint_fabric_administrator.service.as?(Matter::Commissioning::JointFabricAdministratorService)
    end

    private def persisted_icac(document_name : String = APP_ICAC_DOCUMENT) : Bytes?
      document = persistence.app_document(document_name)
      document ? IcacCertificateState.from_document(document).certificate : nil
    end

    private def persist_icac(certificate : Bytes?, document_name : String,
                             administrator : Admin) : Nil
      # The service exposes the post-commit cluster document while this
      # callback runs. Both documents must reach the backend together: a
      # restart after this transaction must restore the committed index.
      cluster_document = administrator.save_state ||
                         raise Matter::StorageError.new("JFA cluster has no persistent state")
      backend = persistence.backend
      app_collection = Matter::Storage::Collections::APP
      cluster_collection = Matter::Storage::Collections::CLUSTERS
      cluster_key = administrator.persistence_key
      backend.transaction do
        if certificate
          backend.write(app_collection, document_name, IcacCertificateState.new(certificate).to_document)
        else
          backend.delete(app_collection, document_name)
        end
        backend.write(cluster_collection, cluster_key, cluster_document)
      end
    end

    private def persist_bootstrap_icac(certificate : Bytes?, administrator : Admin,
                                       datastore : Datastore) : Nil
      # AddICAC on endpoint 2 can join a new fabric while the original
      # bootstrap fabric remains on this endpoint. The committed ICAC belongs
      # to the fabric selected by AddICAC, not necessarily the bootstrap one.
      document_name = administrator.administrator_fabric_index == datastore.joint_fabric_index ? APP_BOOTSTRAP_ICAC_DOCUMENT : APP_ICAC_DOCUMENT
      persist_icac(certificate, document_name, administrator)
    end

    private def restore_bootstrap_administrator_binding : Nil
      document = persistence.app_document(APP_BOOTSTRAP_BINDING_DOCUMENT) || return
      binding = FabricBindingState.from_document(document)
      fabric = fabric_table.get_fabric(binding.fabric_index) || return
      return unless binding.matches?(fabric)
      return if bootstrap_joint_fabric_administrator.administrator_fabric_index == fabric.fabric_index

      # The AddICAC service provisionally used endpoint 2 for the newly joined
      # fabric. After its ICAC is committed and endpoint 1 is activated,
      # rebind endpoint 2 to its independently addressable bootstrap fabric.
      attach_joint_fabric(fabric)
      unless persistence.save_cluster(bootstrap_joint_fabric_administrator)
        raise Matter::StorageError.new("Could not persist bootstrap Joint Fabric Administrator binding")
      end
      persistence.flush
    end

    private def bootstrap_anchor_role? : Bool
      bootstrap_role_state.anchor?
    end

    private def bootstrap_role_state : JointFabricRoleState
      document = persistence.app_document(APP_BOOTSTRAP_ROLE_DOCUMENT)
      document ? JointFabricRoleState.from_document(document) : JointFabricRoleState.new(true)
    end

    private def persist_bootstrap_anchor_role(anchor : Bool, transfer_complete : Bool = false) : Nil
      persistence.write_app_document(APP_BOOTSTRAP_ROLE_DOCUMENT,
        JointFabricRoleState.new(anchor, transfer_complete).to_document)
      bootstrap_joint_fabric_datastore.access_mode = if anchor
                                                       Datastore::AccessMode::Active
                                                     elsif transfer_complete
                                                       Datastore::AccessMode::Inactive
                                                     else
                                                       Datastore::AccessMode::Frozen
                                                     end
      @bootstrap_datastore_propagator.try(&.start) if anchor && @propagation_started
    end

    private def begin_bootstrap_anchor_transfer : Nil
      unless bootstrap_joint_fabric_datastore.begin_anchor_transfer
        raise Matter::ConfigurationError.new("Bootstrap Datastore changed while Anchor transfer was starting")
      end
      @bootstrap_datastore_propagator.try(&.stop!)
      if joint_fabric_datastore.joint_fabric_index == bootstrap_joint_fabric_datastore.joint_fabric_index
        unless joint_fabric_datastore.status.state.delete_pending? || joint_fabric_datastore.begin_anchor_transfer
          raise Matter::ConfigurationError.new("Joint Datastore changed while bootstrap Anchor transfer was starting")
        end
        @datastore_propagator.try(&.stop!)
        persist_anchor_role(false)
      end
      persist_bootstrap_anchor_role(false)
      lifecycle.sync_advertisements
    end

    private def record_bootstrap_transfer_candidate(node_id : UInt64, fabric_index : UInt8) : Nil
      fabric = fabric_table.get_fabric(fabric_index) ||
               raise Matter::AuthenticationError.new("Bootstrap transfer requester fabric is unavailable")
      unless bootstrap_joint_fabric_datastore.joint_fabric_index == fabric_index &&
             node_id != Matter::DataType::NodeId::UNSPECIFIED
        raise Matter::AuthenticationError.new("Transfer requester is not on the bootstrap fabric")
      end
      persistence.write_app_document(APP_BOOTSTRAP_TRANSFER_WATCH_DOCUMENT,
        TransferWatchState.new(node_id, fabric.fabric_id, fabric.root_public_key,
          configured_new_anchor_node_id(node_id)).to_document)
      persistence.flush
    end

    private def persisted_anchor_role : Bool
      document = persistence.app_document(APP_ROLE_DOCUMENT)
      document ? JointFabricRoleState.from_document(document).anchor? : true
    end

    private def persisted_transfer_complete? : Bool
      document = persistence.app_document(APP_ROLE_DOCUMENT)
      document ? JointFabricRoleState.from_document(document).transfer_complete? : false
    end

    private def persist_anchor_role(anchor : Bool, transfer_complete : Bool = false) : Nil
      persistence.write_app_document(APP_ROLE_DOCUMENT, JointFabricRoleState.new(anchor, transfer_complete).to_document)
      @anchor_role = anchor
      joint_fabric_datastore.access_mode = if anchor
                                             Datastore::AccessMode::Active
                                           elsif transfer_complete
                                             Datastore::AccessMode::Inactive
                                           else
                                             Datastore::AccessMode::Frozen
                                           end
      @datastore_propagator.try(&.start) if anchor && @propagation_started
    end

    private def begin_anchor_transfer : Nil
      unless joint_fabric_datastore.begin_anchor_transfer
        raise Matter::ConfigurationError.new("Datastore changed while Anchor transfer was starting")
      end
      @datastore_propagator.try(&.stop!)
      if bootstrap_joint_fabric_datastore.joint_fabric_index == joint_fabric_datastore.joint_fabric_index
        begin_bootstrap_anchor_transfer
      end
      persist_anchor_role(false)
      lifecycle.sync_advertisements
    end

    private def record_transfer_candidate(node_id : UInt64, fabric_index : UInt8) : Nil
      fabric = fabric_table.get_fabric(fabric_index) ||
               raise Matter::AuthenticationError.new("Transfer requester fabric is unavailable")
      unless joint_fabric_datastore.joint_fabric_index == fabric_index &&
             node_id != Matter::DataType::NodeId::UNSPECIFIED
        raise Matter::AuthenticationError.new("Transfer requester is not on the Anchor fabric")
      end
      new_anchor_node_id = configured_new_anchor_node_id(node_id)
      persistence.write_app_document(APP_TRANSFER_WATCH_DOCUMENT,
        TransferWatchState.new(node_id, fabric.fabric_id, fabric.root_public_key, new_anchor_node_id).to_document)
      persistence.flush
      @participant_view_current = false
      ::Log.for("matter.example.joint_fabric_administrator").info do
        "Recorded authenticated Anchor transfer requester 0x#{node_id.to_s(16)}"
      end
    end

    private def persisted_transfer_requester(fabric : Matter::Fabric,
                                             datastore : Datastore,
                                             document_name : String = APP_TRANSFER_WATCH_DOCUMENT) : Tuple(UInt64, UInt8)?
      return unless datastore.status.state.delete_pending?
      document = persistence.app_document(document_name)
      return unless document
      watch = TransferWatchState.from_document(document)
      return unless watch.old_fabric_id == fabric.fabric_id &&
                    watch.old_root_public_key == fabric.root_public_key &&
                    watch.requester_node_id != Matter::DataType::NodeId::UNSPECIFIED
      {watch.requester_node_id, fabric.fabric_index}
    end

    # The wire request identifies B on the old fabric. A local, provisioned
    # mapping binds that authenticated identity to B's Node ID on its own fabric.
    # Without this binding the old Anchor remains fail closed after transfer.
    private def configured_new_anchor_node_id(requester_node_id : UInt64) : UInt64?
      entries = ENV["MATTER_JFA_TRANSFER_CANDIDATE_IDS"]?
      return unless entries
      matching = entries.split(',').select do |entry|
        entry.split('=', 2).first.to_u64?(16) == requester_node_id
      end
      raise Matter::ConfigurationError.new("Duplicate Anchor candidate mapping") if matching.size > 1
      return if matching.empty?
      value = matching.first.split('=', 2)[1]?.try(&.to_u64?(16))
      if value.nil? || value == 0_u64
        raise Matter::ConfigurationError.new("Invalid new Anchor Node ID mapping")
      end
      value
    end

    private def poll_new_anchor_subscription : Nil
      return if @watch_stopped || @watch_polling || general_commissioning.failsafe_armed?
      document = persistence.app_document(APP_TRANSFER_WATCH_DOCUMENT)
      return unless document
      watch = TransferWatchState.from_document(document)
      new_anchor_node_id = watch.new_anchor_node_id
      unless new_anchor_node_id
        @participant_view_current = false
        return
      end
      candidates = fabric_table.all_fabrics.select do |fabric|
        fabric.fabric_id != watch.old_fabric_id || fabric.root_public_key != watch.old_root_public_key
      end
      unless candidates.size == 1
        @participant_view_current = false
        close_new_anchor_subscription
        return
      end
      fabric = candidates.first
      invalidate_new_anchor_subscription_unless(fabric.fabric_id, fabric.root_public_key)
      @watch_polling = true
      begin
        subscription = @new_anchor_subscription
        if subscription
          status = subscription.poll_status(100.milliseconds) || subscription.last_status
        else
          root = fabric.root_cert || raise Matter::ConfigurationError.new("New Anchor fabric has no root certificate")
          identity = Matter::Controller::FabricInfo.new(
            fabric_id: fabric.fabric_id, controller_node_id: fabric.node_id,
            ipk_value: fabric.ipk, root_cert: root, root_public_key: fabric.root_public_key,
            controller_noc: fabric.operational_cert,
            controller_private_key: fabric.operational_private_key,
            admin_vendor_id: fabric.vendor_id,
            intermediate_cert: fabric.intermediate_cert,
            ipk_epoch_keys: fabric.ipk_epoch_keys)
          scanner = Matter::Controller::Scanner.new
          scanner.start
          @new_anchor_scanner = scanner
          subscription = Matter::Controller::AnchorDatastoreSubscription.new(
            scanner, identity, new_anchor_node_id, nil,
            ->(_im : Matter::Controller::ImClient, session : Matter::Session::SecureContext, _peer : Socket::IPAddress) { verify_new_anchor_session!(session) },
            counter_store: @controller_store || Matter::Controller::StateStore.new(persistence.backend),
            shared_message_counter: message_handler.transport.message_counter,
            address_hint: configured_transfer_peer(new_anchor_node_id))
          @new_anchor_subscription = subscription
          @subscribed_fabric_id = fabric.fabric_id
          @subscribed_root_public_key = fabric.root_public_key.dup
          status = subscription.initial_status
        end
        @participant_view_current = status.state == Datastore::DatastoreStateEnum::Committed
      rescue ex : Matter::Error | IO::Error | ArgumentError
        @participant_view_current = false
        close_new_anchor_subscription
        ::Log.for("matter.example.joint_fabric_administrator").warn(exception: ex) do
          "New Anchor Datastore subscription is unavailable; participant view is stale"
        end
      ensure
        @watch_polling = false
      end
    end

    private def verify_new_anchor_session!(session : Matter::Session::SecureContext) : Nil
      has_anchor_cat = session.peer_subject_ids.any? do |subject|
        node = Matter::DataType::NodeId.new(subject)
        if node.case_authenticated_tag?
          cat = node.extract_as_case_authenticated_tag
          cat.identity_value == ANCHOR_CAT_ID && cat.version > 0_u16
        else
          false
        end
      end
      raise Matter::AuthenticationError.new("New Anchor CASE peer lacks Anchor CAT") unless has_anchor_cat
      icac = session.peer_icac || raise Matter::AuthenticationError.new("New Anchor CASE peer lacks ICAC")
      subject = TLV::Any.from_slice(icac).as_structure[Matter::Crypto::MatterCertificate::Asn1::Field::Subject.value].as_list
      unless subject.any? do |entry|
               entry.header.ids == Matter::Crypto::MatterCertificate::Asn1::Dn::OrgUnitName.value &&
               entry.as_s? == Matter::Crypto::MatterCertificate::Builder::ANCHOR_ICAC_ORGANIZATIONAL_UNIT
             end
        raise Matter::AuthenticationError.new("New Anchor ICAC lacks jf-anchor-icac organization unit")
      end
    end

    private def close_new_anchor_subscription : Nil
      @new_anchor_subscription.try(&.close)
      @new_anchor_subscription = nil
      @new_anchor_scanner.try(&.close)
      @new_anchor_scanner = nil
      @subscribed_fabric_id = nil
      @subscribed_root_public_key = nil
    end

    private def invalidate_new_anchor_subscription_unless(fabric_id : UInt64, root_public_key : Bytes) : Nil
      return unless @subscribed_fabric_id
      return if @subscribed_fabric_id == fabric_id && @subscribed_root_public_key == root_public_key
      @participant_view_current = false
      close_new_anchor_subscription
    end

    # An explicit console command is the candidate's user consent. Resolve
    # all peers and obtain a consistent committed Datastore before asking the
    # old Anchor to freeze; network operations after that point are journaled.
    private def transfer_anchor_from(old_anchor_node_id : UInt64,
                                     interrupt_before_follow_up : Bool = false,
                                     interrupt_after_first_follow_up : Bool = false,
                                     interrupt_after_request : Bool = false,
                                     interrupt_before_copy_journal : Bool = false,
                                     interrupt_after_copy : Bool = false,
                                     interrupt_after_rotation : Bool = false,
                                     interrupt_after_first_administrator_rotation : Bool = false,
                                     interrupt_after_second_administrator_rotation : Bool = false,
                                     interrupt_after_promotion : Bool = false,
                                     interrupt_after_complete : Bool = false,
                                     interrupt_after_next_cross_sign : Bool = false,
                                     interrupt_before_next_cross_sign_journal : Bool = false,
                                     interrupt_before_next_pending_icac_journal : Bool = false,
                                     interrupt_after_next_old_fabric_removed : Bool = false,
                                     reconcile_promoting : Bool = false,
                                     reconcile_rotating_administrator : Bool = false,
                                     reconcile_copying : Bool = false,
                                     reconciliation_nonce : String? = nil,
                                     reconciliation_target_node_id : UInt64? = nil) : Nil
      raise Matter::ConfigurationError.new("Anchor transfer already running") if @transfer_in_progress
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Candidate Anchor fabric is not provisioned")
      old_fabrics = fabric_table.all_fabrics.select do |fabric|
        fabric.root_public_key != own_fabric.root_public_key &&
          fabric.cats.any?(&.identity_value.==(ADMINISTRATOR_CAT_ID))
      end
      unless old_fabrics.size == 1
        raise Matter::ConfigurationError.new("Candidate must have exactly one joined Joint Fabric with Administrator CAT")
      end
      old_fabric = old_fabrics.first
      bootstrap = provisioned_anchor_bootstrap(own_fabric)
      old_identity = Matter::Controller::FabricInfo.new(
        fabric_id: old_fabric.fabric_id, controller_node_id: old_fabric.node_id,
        ipk_value: old_fabric.ipk, root_cert: old_fabric.root_cert.as(Bytes),
        root_public_key: old_fabric.root_public_key,
        controller_noc: old_fabric.operational_cert,
        controller_private_key: old_fabric.operational_private_key,
        admin_vendor_id: old_fabric.vendor_id,
        intermediate_cert: old_fabric.intermediate_cert,
        ipk_epoch_keys: old_fabric.ipk_epoch_keys)
      scanner = Matter::Controller::Scanner.new
      old_client = leased_case_client(old_fabric.node_id)
      own_client = leased_case_client(bootstrap.fabric.controller_node_id)
      own_im = Matter::Controller::ImClient.new(own_client)
      journal = if document = persistence.app_document(APP_TRANSFER_DOCUMENT)
                  Matter::Controller::AnchorTransfer::Journal.from_document(document)
                else
                  Matter::Controller::AnchorTransfer::Journal.new(old_fabric.node_id)
                end
      unless journal.candidate_node_id == old_fabric.node_id
        raise Matter::ConfigurationError.new("Existing transfer journal belongs to another candidate")
      end
      journal.capture_candidate_credential!(own_fabric) if journal.stage.ready?
      if reconcile_promoting && !journal.stage.promoting?
        raise Matter::ConfigurationError.new("Anchor transfer is not awaiting promotion reconciliation")
      end
      if reconcile_copying && (!journal.stage.copying? || journal.active_rotation_node_id ||
         !journal.rotated_administrator_node_ids.empty?)
        raise Matter::ConfigurationError.new("Anchor transfer is not awaiting Datastore copy reconciliation")
      end
      if reconcile_rotating_administrator
        rotation_target_node_id = reconciliation_target_node_id || old_anchor_node_id
        unless reconciliation_nonce && reconciliation_nonce.size == ROTATION_NONCE_HEX_LENGTH &&
               reconciliation_nonce.matches?(/\A[0-9a-fA-F]+\z/)
          raise Matter::ConfigurationError.new("A 32-byte hexadecimal rotation nonce is required")
        end
        if !journal.stage.rotating? || journal.active_rotation_node_id != rotation_target_node_id ||
           journal.rotated_administrator_node_ids.includes?(rotation_target_node_id)
          raise Matter::ConfigurationError.new("Anchor transfer is not awaiting the requested Administrator rotation")
        end
      end
      @transfer_in_progress = true
      begin
        return if journal.stage.completed?
        scanner.start
        scanner.query_operational
        if journal.stage.completing?
          raise Matter::CommissioningError.new("Anchor transfer needs authenticated completion reconciliation")
        end
        if journal.stage.transferred? || journal.stage.following_up?
          unless journal.stage.following_up?
            journal.stage = Matter::Controller::AnchorTransfer::Stage::FollowingUp
            persistence.write_app_document(APP_TRANSFER_DOCUMENT, journal.to_document)
            persistence.flush
          end
          if interrupt_before_follow_up
            raise Matter::TransportError.new("Injected interruption before Anchor transfer follow-up")
          end
          follow_up_administrators(joint_fabric_datastore, old_fabric, scanner, own_client, own_im,
            interrupt_after_first_follow_up, interrupt_after_next_cross_sign,
            interrupt_before_next_cross_sign_journal,
            interrupt_after_next_old_fabric_removed: interrupt_after_next_old_fabric_removed,
            interrupt_before_next_pending_icac_journal: interrupt_before_next_pending_icac_journal)
          journal.stage = Matter::Controller::AnchorTransfer::Stage::Completed
          persistence.write_app_document(APP_TRANSFER_DOCUMENT, journal.to_document)
          persistence.flush
          return
        end
        old_peer = resolve_transfer_peer(scanner, old_identity.compressed_fabric_id, old_anchor_node_id)
        old_session = Matter::Controller::Pairing::CasePairing.new.pair(old_client, old_peer,
          old_identity, peer_node_id: old_anchor_node_id)
        old_im = Matter::Controller::ImClient.new(old_client)
        old_endpoint = Matter::Controller::JointCommissioning.discover_administrator_endpoint(
          old_im, old_session, old_peer)
        # Requesting may mean the old Anchor froze its Datastore before the
        # acknowledgement was lost. Read both valid states over CASE, then
        # resolve that uncertainty before the workflow can send a request.
        expected_frozen = if journal.stage.ready?
                            false
                          elsif journal.stage.requesting?
                            nil
                          else
                            true
                          end
        preflight = Matter::Controller::AnchorTransfer::Snapshot.read_remote(old_im, old_session, old_peer,
          old_endpoint, require_frozen: expected_frozen)
        if journal.stage.requesting? && preflight.status.state.delete_pending?
          raise Matter::CommissioningError.new("Frozen Anchor transfer needs authenticated requester reconciliation")
        end
        unless preflight.anchor_node_id == old_anchor_node_id
          raise Matter::AuthenticationError.new("Discovered node is not the Datastore Anchor")
        end
        # Verify that each participant supplied a usable ICAC before freezing A.
        preflight.admin_list.each do |admin|
          next if admin.node_id == old_fabric.node_id
          certificate = Matter::Crypto::MatterCertificate.from_slice(admin.icac)
          unless certificate.subject.icac_id
            raise Matter::ConfigurationError.new("Administrator 0x#{admin.node_id.to_s(16)} lacks an ICAC ID")
          end
          Matter::Crypto::MatterCertificate.public_key_from_tlv(admin.icac)
        end
        admin_version = next_transfer_cat_version(preflight, ADMINISTRATOR_CAT_ID)
        anchor_version = next_transfer_cat_version(preflight, ANCHOR_CAT_ID)

        rotations = [] of Matter::Controller::AnchorTransfer::CredentialTransition
        preflight.admin_list.each do |admin|
          node_id = admin.node_id
          next if node_id == old_fabric.node_id
          peer = node_id == old_anchor_node_id ? old_peer : resolve_transfer_peer(scanner, old_identity.compressed_fabric_id, node_id)
          session = node_id == old_anchor_node_id ? old_session : Matter::Controller::Pairing::CasePairing.new.pair(old_client, peer,
            old_identity, peer_node_id: node_id)
          rotations << Matter::Controller::AnchorTransfer::AdministratorRotation.new(old_client, old_im,
            session, peer, node_id, bootstrap, admin_version, anchor_version)
        end

        own_peer = Socket::IPAddress.new("127.0.0.1", port)
        own_session = Matter::Controller::Pairing::CasePairing.new.pair(own_client, own_peer,
          bootstrap.fabric, peer_node_id: own_fabric.node_id)
        own_rotation = Matter::Controller::AnchorTransfer::AdministratorRotation.new(own_client, own_im,
          own_session, own_peer, own_fabric.node_id, bootstrap,
          admin_version, anchor_version, anchor_target: true,
          existing_fabric: true, existing_fabric_index: own_fabric.fabric_index)
        own_icac = bootstrap.fabric.intermediate_cert ||
                   raise Matter::ConfigurationError.new("Candidate Anchor ICAC is unavailable")
        candidate_administrator = Datastore::DatastoreAdministratorInformationEntryStruct.new(
          own_fabric.node_id, DEFAULT_ANCHOR_FRIENDLY_NAME, own_fabric.vendor_id, own_icac)
        migration = Matter::Controller::AnchorTransfer::RotationMigration.new(old_im, old_session, old_peer,
          old_endpoint, joint_fabric_datastore, own_fabric.node_id, bootstrap,
          rotations, own_rotation,
          -> {
            persist_transfer_candidate_datastore!
            if interrupt_before_copy_journal && journal.stage.copying?
              raise Matter::TransportError.new("Injected interruption after durable copy before Copied journal save")
            end
            if interrupt_after_first_administrator_rotation && journal.stage.rotating? &&
               journal.active_rotation_node_id == old_anchor_node_id
              raise Matter::TransportError.new("Injected interruption after durable first Administrator rotation")
            end
            if interrupt_after_second_administrator_rotation && journal.stage.rotating? &&
               journal.active_rotation_node_id != old_anchor_node_id &&
               journal.rotated_administrator_node_ids.includes?(old_anchor_node_id)
              raise Matter::TransportError.new("Injected interruption after durable second Administrator rotation")
            end
            nil
          },
          -> {
            select_anchor_administrator_fabric(own_fabric.fabric_index)
            persist_anchor_role(true)
            if interrupt_after_promotion
              persistence.flush
              raise Matter::TransportError.new("Injected interruption after durable Anchor promotion")
            end
            @transfer_in_progress = false
            lifecycle.sync_advertisements
            nil
          },
          administrator_cat_version: admin_version,
          anchor_cat_version: anchor_version,
          candidate_old_node_id: old_fabric.node_id,
          candidate_administrator: candidate_administrator,
          finalize_administrators: -> {
            if interrupt_before_follow_up
              raise Matter::TransportError.new("Injected interruption before Anchor transfer follow-up")
            end
            follow_up_administrators(preflight, old_fabric, scanner, own_client, own_im,
              interrupt_after_first_follow_up, interrupt_after_next_cross_sign,
              interrupt_before_next_cross_sign_journal,
              interrupt_after_next_old_fabric_removed: interrupt_after_next_old_fabric_removed,
              interrupt_before_next_pending_icac_journal: interrupt_before_next_pending_icac_journal)
            nil
          })
        port = Matter::Controller::AnchorTransfer::ImPort.new(old_im, old_session, old_peer, old_endpoint)
        transfer_port = (interrupt_after_request || interrupt_after_complete) ? InterruptedTransferPort.new(port, interrupt_after_request, interrupt_after_complete) : port
        workflow = Matter::Controller::AnchorTransfer::Workflow.new(preflight,
          transfer_port, migration,
          -> { true },
          ->(state : Matter::Controller::AnchorTransfer::Journal) {
            persistence.write_app_document(APP_TRANSFER_DOCUMENT, state.to_document)
            persistence.flush
            # Test-only lost acknowledgement after the copied Datastore and
            # Copied journal have both reached durable storage.
            if interrupt_after_copy && state.stage.copied?
              raise Matter::TransportError.new("Injected interruption after durable Anchor Datastore copy")
            end
            if interrupt_after_rotation && state.stage.rotated?
              raise Matter::TransportError.new("Injected interruption after durable Administrator rotations")
            end
            nil
          }, journal)
        workflow.reconcile_request!(preflight.status.state) if journal.stage.requesting?
        if reconcile_promoting
          verify_durable_transfer_promotion!(journal, preflight, old_anchor_node_id, old_fabric, own_fabric,
            bootstrap, admin_version, anchor_version)
          workflow.reconcile!(Matter::Controller::AnchorTransfer::Stage::Promoted)
          return
        end
        if reconcile_copying
          verify_durable_transfer_copy!(journal, preflight, old_anchor_node_id, old_fabric,
            own_fabric, bootstrap, admin_version, anchor_version)
          workflow.reconcile!(Matter::Controller::AnchorTransfer::Stage::Copied)
          return
        end
        if reconcile_rotating_administrator
          nonce = reconciliation_nonce || raise Matter::ConfigurationError.new("Rotation nonce is unavailable")
          target_node_id = reconciliation_target_node_id || old_anchor_node_id
          verify_durable_transfer_rotation!(journal, preflight, old_anchor_node_id, old_fabric,
            own_fabric, bootstrap, admin_version, anchor_version, target_node_id)
          target_peer = target_node_id == old_anchor_node_id ? old_peer : resolve_transfer_peer(scanner, old_identity.compressed_fabric_id, target_node_id)
          new_session = Matter::Controller::Pairing::CasePairing.new.pair(own_client, target_peer,
            bootstrap.fabric, peer_node_id: target_node_id)
          Matter::Controller::AdministratorRemoval::RotationInspection.verify_completed!(
            own_im, new_session, target_peer, bootstrap.fabric.root_cert,
            bootstrap.fabric.fabric_id, bootstrap.fabric.root_public_key,
            target_node_id, admin_version, nonce.hexbytes,
            exact_cats: [Matter::DataType::CaseAuthenticatedTag.create(ADMINISTRATOR_CAT_ID, admin_version)])
          workflow.reconcile_completed_rotation!(target_node_id)
          return
        end
        workflow.run
      ensure
        @transfer_in_progress = false
        old_client.close
        own_client.close
        scanner.close
      end
    end

    private def persist_transfer_candidate_datastore! : Nil
      unless persistence.save_cluster(joint_fabric_datastore)
        raise Matter::StorageError.new("Could not persist transferred Anchor Datastore")
      end
      persistence.flush
    end

    private def verify_durable_transfer_rotation!(journal : Matter::Controller::AnchorTransfer::Journal,
                                                  source : Datastore, old_anchor_node_id : UInt64,
                                                  old_fabric : Matter::Fabric, own_fabric : Matter::Fabric,
                                                  bootstrap : Matter::Controller::JointCommissioning::AnchorBootstrap,
                                                  admin_version : UInt16, anchor_version : UInt16,
                                                  target_node_id : UInt64) : Nil
      unless journal.stage.rotating? && journal.candidate_node_id == old_fabric.node_id &&
             journal.active_rotation_node_id == target_node_id &&
             source.status.state.delete_pending? && source.anchor_root_ca == old_fabric.root_cert &&
             source.anchor_node_id == old_anchor_node_id
        raise Matter::AuthenticationError.new("Old Anchor rotation lacks the expected frozen transfer")
      end
      rotation_order = source.admin_list.map(&.node_id).reject(&.==(old_fabric.node_id))
      Matter::Controller::AnchorTransfer::Workflow.verify_rotation_prefix!(journal,
        rotation_order, target_node_id)
      verify_unpromoted_transfer_candidate!(journal, source, old_fabric, own_fabric, bootstrap,
        admin_version, anchor_version)
    end

    private def verify_durable_transfer_copy!(journal : Matter::Controller::AnchorTransfer::Journal,
                                              source : Datastore, old_anchor_node_id : UInt64,
                                              old_fabric : Matter::Fabric, own_fabric : Matter::Fabric,
                                              bootstrap : Matter::Controller::JointCommissioning::AnchorBootstrap,
                                              admin_version : UInt16, anchor_version : UInt16) : Nil
      unless journal.stage.copying? && journal.candidate_node_id == old_fabric.node_id &&
             journal.active_rotation_node_id.nil? && journal.rotated_administrator_node_ids.empty? &&
             source.status.state.delete_pending? && source.anchor_root_ca == old_fabric.root_cert &&
             source.anchor_node_id == old_anchor_node_id
        raise Matter::AuthenticationError.new("Anchor copy lacks the expected frozen transfer")
      end
      verify_unpromoted_transfer_candidate!(journal, source, old_fabric, own_fabric, bootstrap,
        admin_version, anchor_version)
    end

    private def verify_unpromoted_transfer_candidate!(journal : Matter::Controller::AnchorTransfer::Journal,
                                                      source : Datastore, old_fabric : Matter::Fabric,
                                                      own_fabric : Matter::Fabric,
                                                      bootstrap : Matter::Controller::JointCommissioning::AnchorBootstrap,
                                                      admin_version : UInt16, anchor_version : UInt16) : Nil
      durable_fabric = verify_durable_anchor_old_credential!(own_fabric)
      verify_unpromoted_candidate_credential!(journal, durable_fabric, bootstrap)
      durable_old_fabric = verify_durable_anchor_old_credential!(old_fabric)
      unless durable_old_fabric.root_cert == old_fabric.root_cert
        raise Matter::AuthenticationError.new("Joined old fabric root changed during rotation")
      end
      verify_unpromoted_transfer_bindings_and_roles!(durable_old_fabric, durable_fabric)
      verify_durable_transfer_datastore!(source, old_fabric.node_id, own_fabric, bootstrap,
        admin_version, anchor_version, promoted: false)
      verify_transfer_datastore_equivalent!(joint_fabric_datastore, durable_transfer_datastore,
        "Candidate Anchor live Datastore differs from its durable copy")
    end

    private def verify_unpromoted_candidate_credential!(journal : Matter::Controller::AnchorTransfer::Journal,
                                                        fabric : Matter::Fabric,
                                                        bootstrap : Matter::Controller::JointCommissioning::AnchorBootstrap) : Nil
      actual_cats = Matter::Crypto::MatterCertificate.subject_ids_from_tlv(fabric.operational_cert)
        .compact_map { |subject| Matter::DataType::NodeId.case_authenticated_tag_from_subject?(subject) }
        .sort_by!(&.value)
      recorded_cats = journal.candidate_cat_values
      recorded_noc = journal.candidate_operational_cert
      recorded_icac = journal.candidate_intermediate_cert
      unless fabric.fabric_id == bootstrap.fabric.fabric_id &&
             fabric.root_public_key == bootstrap.fabric.root_public_key &&
             fabric.root_cert == bootstrap.fabric.root_cert &&
             recorded_noc && recorded_icac && recorded_cats &&
             journal.candidate_credential_matches?(fabric) &&
             fabric.cats.sort_by(&.value) == actual_cats &&
             actual_cats.map(&.value).sort! == recorded_cats.sort
        raise Matter::AuthenticationError.new("Candidate fabric differs from saved pre-transfer credentials")
      end
    end

    private def verify_unpromoted_transfer_bindings_and_roles!(old_fabric : Matter::Fabric,
                                                               own_fabric : Matter::Fabric) : Nil
      old_binding = persistence.app_document(APP_FABRIC_BINDING_DOCUMENT) ||
                    raise Matter::StorageError.new("Joined old fabric binding is absent")
      new_binding = persistence.app_document(APP_BOOTSTRAP_BINDING_DOCUMENT) ||
                    raise Matter::StorageError.new("Candidate bootstrap binding is absent")
      unless FabricBindingState.from_document(old_binding).matches?(old_fabric) &&
             FabricBindingState.from_document(new_binding).matches?(own_fabric)
        raise Matter::AuthenticationError.new("Candidate fabric bindings differ from interrupted transfer")
      end
      old_administrator = durable_transfer_administrator(ANCHOR_JFA_ENDPOINT_ID)
      new_administrator = durable_transfer_administrator(BOOTSTRAP_JFA_ENDPOINT_ID)
      unless old_administrator.administrator_fabric_index == old_fabric.fabric_index &&
             new_administrator.administrator_fabric_index == own_fabric.fabric_index
        raise Matter::AuthenticationError.new("Candidate Administrator endpoints changed during rotation")
      end
      joined_role_document = persistence.app_document(APP_ROLE_DOCUMENT) ||
                             raise Matter::StorageError.new("Joined Administrator role is absent")
      joined_role = JointFabricRoleState.from_document(joined_role_document)
      bootstrap_role = bootstrap_role_state
      if joined_role.anchor? || joined_role.transfer_complete? ||
         !bootstrap_role.anchor? || bootstrap_role.transfer_complete?
        raise Matter::AuthenticationError.new("Candidate Administrator roles changed during rotation")
      end
    end

    # Promotion changes B's NOC, Datastore, endpoint binding, and role in that
    # order. A restart at Promoting must inspect their durable results before
    # deciding that the candidate NOC rotation must never be repeated.
    private def verify_durable_transfer_promotion!(journal : Matter::Controller::AnchorTransfer::Journal,
                                                   source : Datastore, old_anchor_node_id : UInt64,
                                                   old_fabric : Matter::Fabric,
                                                   own_fabric : Matter::Fabric,
                                                   bootstrap : Matter::Controller::JointCommissioning::AnchorBootstrap,
                                                   admin_version : UInt16, anchor_version : UInt16) : Nil
      verify_frozen_transfer_source!(journal, source, old_anchor_node_id, old_fabric)
      if !persistence.backend.durable? || general_commissioning.failsafe_armed? ||
         persistence.backend.read(Matter::Commissioning::CredentialJournal::COLLECTION,
           Matter::Commissioning::CredentialJournal::ID)
        raise Matter::StorageError.new("Anchor promotion credentials are not durably committed")
      end
      durable_fabric = verify_durable_anchor_old_credential!(own_fabric)
      expected_cats = [
        Matter::DataType::CaseAuthenticatedTag.create(ADMINISTRATOR_CAT_ID, admin_version),
        Matter::DataType::CaseAuthenticatedTag.create(ANCHOR_CAT_ID, anchor_version),
      ].sort_by(&.value)
      certificate_cats = Matter::Crypto::MatterCertificate.subject_ids_from_tlv(durable_fabric.operational_cert)
        .compact_map { |subject| Matter::DataType::NodeId.case_authenticated_tag_from_subject?(subject) }
        .sort_by!(&.value)
      unless durable_fabric.fabric_id == bootstrap.fabric.fabric_id &&
             durable_fabric.root_public_key == bootstrap.fabric.root_public_key &&
             durable_fabric.root_cert == bootstrap.fabric.root_cert &&
             durable_fabric.intermediate_cert == bootstrap.fabric.intermediate_cert &&
             durable_fabric.node_id == own_fabric.node_id &&
             durable_fabric.cats.sort_by(&.value) == expected_cats && certificate_cats == expected_cats
        raise Matter::AuthenticationError.new("Candidate Anchor durable NOC does not match the transfer")
      end
      verify_promotion_bindings!(durable_fabric)
      verify_promotion_roles!
      durable_administrator = durable_transfer_administrator(ANCHOR_JFA_ENDPOINT_ID)
      durable_bootstrap_administrator = durable_transfer_administrator(BOOTSTRAP_JFA_ENDPOINT_ID)
      unless durable_administrator.administrator_fabric_index == durable_fabric.fabric_index &&
             durable_bootstrap_administrator.administrator_fabric_index.nil?
        raise Matter::AuthenticationError.new("Candidate Anchor endpoint binding did not finish promotion")
      end
      verify_durable_transfer_datastore!(source, old_fabric.node_id, own_fabric, bootstrap,
        admin_version, anchor_version)
    end

    private def verify_durable_transfer_datastore!(source : Datastore, candidate_old_node_id : UInt64,
                                                   own_fabric : Matter::Fabric,
                                                   bootstrap : Matter::Controller::JointCommissioning::AnchorBootstrap,
                                                   admin_version : UInt16, anchor_version : UInt16,
                                                   promoted : Bool = true) : Nil
      durable_datastore = durable_transfer_datastore
      expected = Datastore.new(Matter::DataType::EndpointNumber.new(ANCHOR_JFA_ENDPOINT_ID))
      candidate_icac = bootstrap.fabric.intermediate_cert ||
                       raise Matter::ConfigurationError.new("Candidate Anchor ICAC is absent")
      candidate_admin = Datastore::DatastoreAdministratorInformationEntryStruct.new(
        own_fabric.node_id, DEFAULT_ANCHOR_FRIENDLY_NAME, own_fabric.vendor_id, candidate_icac)
      Matter::Controller::AnchorTransfer::Snapshot.copy!(source, expected, own_fabric.node_id,
        candidate_old_node_id, candidate_admin)
      keys = bootstrap.fabric.ipk_epoch_keys
      first_epoch = Matter::Controller::AnchorTransfer::RotationMigration::FIRST_IPK_EPOCH_START_TIME
      ipk_key_set = Datastore::DatastoreGroupKeySetStruct.new(Datastore::IPK_KEY_SET_ID,
        Datastore::DatastoreGroupKeySecurityPolicyEnum::TrustFirst,
        keys[0].dup, first_epoch,
        keys[1]?.try(&.dup), keys[1]? ? first_epoch + 1_u64 : nil,
        keys[2]?.try(&.dup), keys[2]? ? first_epoch + 2_u64 : nil)
      key_sets = expected.group_key_set_list
      if index = key_sets.index(&.group_key_set_id.==(Datastore::IPK_KEY_SET_ID))
        key_sets[index] = ipk_key_set
      else
        key_sets.unshift(ipk_key_set)
      end
      expected.group_key_set_list = key_sets
      expected.group_list = expected.group_list.map do |group|
        group.group_cat_version = admin_version if group.group_cat == ADMINISTRATOR_CAT_ID
        group.group_cat_version = anchor_version if group.group_cat == ANCHOR_CAT_ID
        group
      end
      if promoted
        expected.anchor_root_ca = bootstrap.fabric.root_cert.dup
        expected.anchor_node_id = own_fabric.node_id
        expected.anchor_vendor_id = bootstrap.fabric.admin_vendor_id
      end
      verify_transfer_datastore_equivalent!(durable_datastore, expected,
        "Candidate Anchor durable Datastore is incomplete")
    end

    private def verify_transfer_datastore_equivalent!(actual : Datastore, expected : Datastore,
                                                      description : String) : Nil
      checks = {
        "status state"    => actual.status.state == expected.status.state,
        "status time"     => actual.status.update_timestamp == expected.status.update_timestamp,
        "status failure"  => actual.status.failure_code == expected.status.failure_code,
        "root"            => actual.anchor_root_ca == expected.anchor_root_ca,
        "node"            => actual.anchor_node_id == expected.anchor_node_id,
        "vendor"          => actual.anchor_vendor_id == expected.anchor_vendor_id,
        "name"            => actual.friendly_name == expected.friendly_name,
        "key sets"        => actual.group_key_set_list.to_tlv == expected.group_key_set_list.to_tlv,
        "groups"          => actual.group_list.to_tlv == expected.group_list.to_tlv,
        "nodes"           => actual.node_list.to_tlv == expected.node_list.to_tlv,
        "administrators"  => actual.admin_list.to_tlv == expected.admin_list.to_tlv,
        "endpoint groups" => actual.endpoint_group_id_list.to_tlv == expected.endpoint_group_id_list.to_tlv,
        "bindings"        => actual.endpoint_binding_list.to_tlv == expected.endpoint_binding_list.to_tlv,
        "node keys"       => actual.node_key_set_list.to_tlv == expected.node_key_set_list.to_tlv,
        "access lists"    => actual.node_acl_list.to_tlv == expected.node_acl_list.to_tlv,
        "node endpoints"  => actual.node_endpoint_list.to_tlv == expected.node_endpoint_list.to_tlv,
      }
      mismatches = checks.compact_map { |name, matches| name unless matches }
      unless mismatches.empty?
        raise Matter::AuthenticationError.new("#{description}: #{mismatches.join(", ")}")
      end
    end

    private def verify_frozen_transfer_source!(journal : Matter::Controller::AnchorTransfer::Journal,
                                               source : Datastore, old_anchor_node_id : UInt64,
                                               old_fabric : Matter::Fabric) : Nil
      unless journal.stage.promoting? && journal.candidate_node_id == old_fabric.node_id &&
             journal.active_rotation_node_id.nil? && source.status.state.delete_pending? &&
             source.anchor_root_ca == old_fabric.root_cert &&
             source.anchor_node_id == old_anchor_node_id
        raise Matter::AuthenticationError.new("Anchor promotion lacks the expected frozen transfer")
      end
      expected_rotations = source.admin_list.map(&.node_id).reject(&.==(old_fabric.node_id)).sort!
      unless journal.rotated_administrator_node_ids.sort == expected_rotations
        raise Matter::AuthenticationError.new("Anchor promotion has incomplete Administrator rotations")
      end
    end

    private def verify_promotion_bindings!(fabric : Matter::Fabric) : Nil
      {APP_FABRIC_BINDING_DOCUMENT, APP_BOOTSTRAP_BINDING_DOCUMENT}.each do |document_name|
        binding_document = persistence.app_document(document_name) ||
                           raise Matter::StorageError.new("Candidate Anchor fabric binding is absent")
        unless FabricBindingState.from_document(binding_document).matches?(fabric)
          raise Matter::AuthenticationError.new("Candidate Anchor fabric binding changed")
        end
      end
    end

    private def verify_promotion_roles! : Nil
      role_document = persistence.app_document(APP_ROLE_DOCUMENT) ||
                      raise Matter::StorageError.new("Promoted Anchor role is absent")
      bootstrap_role_document = persistence.app_document(APP_BOOTSTRAP_ROLE_DOCUMENT) ||
                                raise Matter::StorageError.new("Bootstrap Anchor role is absent")
      role = JointFabricRoleState.from_document(role_document)
      bootstrap_role = JointFabricRoleState.from_document(bootstrap_role_document)
      if !role.anchor? || role.transfer_complete? || bootstrap_role.anchor? || !bootstrap_role.transfer_complete? ||
         persistence.app_document(APP_ICAC_DOCUMENT)
        raise Matter::AuthenticationError.new("Candidate Anchor role did not finish promotion")
      end
    end

    private def durable_transfer_datastore : Datastore
      document = persistence.backend.read(Matter::Storage::Collections::CLUSTERS,
        joint_fabric_datastore.persistence_key) || raise Matter::StorageError.new("Promoted Datastore is absent")
      saved = Datastore.new(Matter::DataType::EndpointNumber.new(ANCHOR_JFA_ENDPOINT_ID))
      saved.restore_state(document)
      saved
    end

    private def durable_transfer_administrator(endpoint_id : UInt16) : Admin
      saved = Admin.new(Matter::DataType::EndpointNumber.new(endpoint_id))
      document = persistence.backend.read(Matter::Storage::Collections::CLUSTERS,
        saved.persistence_key) || raise Matter::StorageError.new("Promoted Administrator endpoint is absent")
      saved.restore_state(document)
      saved
    end

    # After candidate promotion, VID verification must inspect this device's
    # new Anchor fabric. JCM may have pointed the attribute at the joined old
    # Anchor fabric, so persist the switch before participant follow-up.
    private def select_anchor_administrator_fabric(index : UInt8) : Nil
      fabric = fabric_table.get_fabric(index) ||
               raise Matter::ConfigurationError.new("Promoted Anchor fabric is unavailable")
      bootstrap_binding = persistence.app_document(APP_BOOTSTRAP_BINDING_DOCUMENT) ||
                          raise Matter::ConfigurationError.new("Promoted Anchor bootstrap binding is unavailable")
      unless FabricBindingState.from_document(bootstrap_binding).matches?(fabric) && compliant_anchor_fabric?(fabric)
        raise Matter::AuthenticationError.new("Promoted Anchor fabric does not match its bootstrap binding")
      end
      cluster = joint_fabric_administrator
      cluster.administrator_fabric_index = index
      joint_fabric_datastore.joint_fabric_index = index
      @bootstrap_datastore_propagator.try(&.stop!)
      bootstrap_joint_fabric_administrator.administrator_fabric_index = nil
      bootstrap_joint_fabric_administrator.service = nil
      persistence.backend.transaction do
        persist_bootstrap_anchor_role(false, transfer_complete: true)
        persist_fabric_binding(fabric, APP_FABRIC_BINDING_DOCUMENT)
        persistence.delete_app_document(APP_ICAC_DOCUMENT)
        unless persistence.save_cluster(cluster) &&
               persistence.save_cluster(joint_fabric_datastore) &&
               persistence.save_cluster(bootstrap_joint_fabric_administrator) &&
               persistence.save_cluster(bootstrap_joint_fabric_datastore)
          raise Matter::StorageError.new("Could not persist promoted Anchor Datastore and Administrator endpoints")
        end
      end
      persistence.flush
      # The persisted binding is also the live service boundary. Without this,
      # endpoint 1 keeps its old joined-fabric JFA window callback until restart.
      attach_joint_fabric(fabric)
    end

    private def follow_up_administrators(source : Datastore, old_fabric : Matter::Fabric,
                                         scanner : Matter::Controller::Scanner,
                                         client : Matter::Controller::Client,
                                         im : Matter::Controller::ImClient,
                                         interrupt_after_first : Bool = false,
                                         interrupt_after_next_cross_sign : Bool = false,
                                         interrupt_before_next_cross_sign_journal : Bool = false,
                                         interrupt_after_next_old_fabric_removed : Bool = false,
                                         reconcile_target_node_id : UInt64? = nil,
                                         reconcile_no_effect : Bool = false,
                                         interrupt_before_next_pending_icac_journal : Bool = false) : Nil
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Candidate Anchor fabric disappeared")
      controller_store = @controller_store || raise Matter::ConfigurationError.new("Candidate controller identity disappeared")
      identity = controller_store.load.fabric_for(own_fabric.fabric_id, own_fabric.root_public_key, own_fabric.node_id)
      scanner.query_operational
      followed_up = 0
      source.admin_list.each do |admin|
        # The frozen source lists our old Joint Fabric Node ID; a restored
        # promoted Datastore instead lists our new Anchor Node ID.
        next if admin.node_id == old_fabric.node_id || admin.node_id == own_fabric.node_id
        next if reconcile_target_node_id && admin.node_id != reconcile_target_node_id
        document_name = "#{APP_FOLLOW_UP_PREFIX}#{admin.node_id.to_s(16)}"
        journal = if document = persistence.app_document(document_name)
                    Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal.from_document(document)
                  else
                    Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal.new(admin.node_id)
                  end
        next if journal.stage.completed?
        icac_id = Matter::Crypto::MatterCertificate.from_slice(admin.icac).subject.icac_id ||
                  raise Matter::ConfigurationError.new("Administrator ICAC ID missing")
        icac_public_key = Matter::Crypto::MatterCertificate.public_key_from_tlv(admin.icac)
        peer = resolve_transfer_peer(scanner, identity.compressed_fabric_id, admin.node_id)
        endpoint = Matter::Controller::JointCommissioning.discover_administrator_endpoint(
          im, Matter::Controller::Pairing::CasePairing.new.pair(client, peer, identity,
          peer_node_id: admin.node_id), peer)
        if reconcile_target_node_id && endpoint != ANCHOR_JFA_ENDPOINT_ID
          raise Matter::AuthenticationError.new("Participant JFA endpoint changed during reconciliation")
        end
        runner = Matter::Controller::AnchorTransfer::AdministratorFollowUp.new(
          client, im, peer, admin.node_id, identity, old_fabric.fabric_id,
          old_fabric.root_public_key, endpoint, icac_public_key, icac_id,
          ->(state : Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal) {
            if interrupt_before_next_pending_icac_journal && state.stage.cross_signing? && state.pending_icac
              raise Matter::TransportError.new("Injected interruption before participant pending ICAC journal save")
            end
            persistence.write_app_document(document_name, state.to_document)
            persistence.flush
            # Test-only lost acknowledgement after a durable CrossSigned save.
            # The next command has no fault flag and resumes at RemovingOld.
            if interrupt_after_next_cross_sign && state.stage.cross_signed?
              raise Matter::TransportError.new("Injected interruption after durable Anchor participant cross-sign")
            end
            nil
          }, journal, consent: -> { true },
          after_old_fabric_removed: -> {
            if interrupt_after_next_old_fabric_removed
              raise Matter::TransportError.new("Injected lost Anchor participant RemoveFabric acknowledgement")
            end
            nil
          },
          on_committed_icac: ->(node_id : UInt64, certificate : Bytes) {
            entries = joint_fabric_datastore.admin_list
            unless entries.any?(&.node_id.==(node_id))
              raise Matter::ConfigurationError.new("Follow-up Administrator is absent from candidate Datastore")
            end
            joint_fabric_datastore.admin_list = entries.map do |entry|
              entry.icac = certificate if entry.node_id == node_id
              entry
            end
            unless persistence.save_cluster(joint_fabric_datastore)
              raise Matter::StorageError.new("Could not persist follow-up Administrator ICAC")
            end
            persistence.flush
            if interrupt_before_next_cross_sign_journal
              raise Matter::TransportError.new("Injected interruption after committed participant cross-sign before journal save")
            end
            nil
          })
        if reconcile_target_node_id
          runner.reconcile_cross_sign!(!reconcile_no_effect)
          return
        end
        runner.run
        followed_up += 1
        if interrupt_after_first && followed_up == 1
          raise Matter::TransportError.new("Injected interruption after first Anchor participant follow-up")
        end
      end
      if reconcile_target_node_id
        raise Matter::ConfigurationError.new("Reconciliation target is absent from the frozen Administrator list")
      end
    end

    # C's private, host-authenticated witness for a committed AddICAC. A
    # nonce alone is freshness, not authentication of the command channel.
    private def inspect_cross_sign_commit(node_id : UInt64, fabric_id : UInt64?,
                                          root_public_key : Bytes?, nonce : String?) : CommandResult
      validate_recovery_nonce!(nonce)
      matches = fabric_table.all_fabrics.select do |candidate|
        candidate.node_id == node_id && candidate.fabric_id == fabric_id &&
          candidate.root_public_key == root_public_key
      end
      if matches.size != 1 || @anchor_role || !@joint_fabric_provisioned
        raise Matter::AuthenticationError.new("Participant does not own the selected joined fabric")
      end
      fabric = matches.first
      certificate = persisted_icac ||
                    raise Matter::ConfigurationError.new("Committed participant ICAC is absent")
      binding_document = persistence.app_document(APP_FABRIC_BINDING_DOCUMENT) ||
                         raise Matter::StorageError.new("Participant fabric binding is absent")
      role_document = persistence.app_document(APP_ROLE_DOCUMENT) ||
                      raise Matter::StorageError.new("Participant role is absent")
      role = JointFabricRoleState.from_document(role_document)
      if role.anchor? || role.transfer_complete?
        raise Matter::AuthenticationError.new("Participant role changed before cross-sign reconciliation")
      end
      durable_administrator = durable_transfer_administrator(ANCHOR_JFA_ENDPOINT_ID)
      unless FabricBindingState.from_document(binding_document).matches?(fabric) &&
             joined_icac_matches_fabric?(certificate, fabric) &&
             joint_fabric_administrator.administrator_fabric_index == fabric.fabric_index &&
             durable_administrator.administrator_fabric_index == fabric.fabric_index &&
             joint_fabric_datastore.joint_fabric_index == fabric.fabric_index &&
             joint_fabric_service.try(&.cross_signed_icac) == certificate
        raise Matter::AuthenticationError.new("Participant committed ICAC or endpoint binding changed")
      end
      verify_durable_anchor_old_credential!(fabric)
      if !persistence.backend.durable? || general_commissioning.failsafe_context ||
         persistence.backend.read(Matter::Commissioning::CredentialJournal::COLLECTION,
           Matter::Commissioning::CredentialJournal::ID)
        raise Matter::CommissioningError.new("Participant cross-sign may still be provisional")
      end
      CommandResult.new("ok", nonce: nonce,
        inspected_cross_signed_icac: certificate,
        inspected_fabric_id: fabric.fabric_id,
        inspected_root_public_key: fabric.root_public_key,
        inspected_node_id: fabric.node_id,
        inspected_administrator_fabric_index: fabric.fabric_index,
        inspected_jfa_endpoint_id: ANCHOR_JFA_ENDPOINT_ID,
        inspected_failsafe_clear: true,
        inspected_credential_journal_clear: true)
    end

    # A participant may have received AddICAC but lost the exchange before
    # CommissioningComplete. A durable old-fabric binding and cleared fail-safe
    # prove the provisional certificate cannot later commit. The private host
    # channel authenticates C; the nonce only prevents reusing an old result.
    private def inspect_cross_sign_no_effect(node_id : UInt64, fabric_id : UInt64?,
                                             root_public_key : Bytes?, old_fabric_id : UInt64?,
                                             old_root_public_key : Bytes?, nonce : String?) : CommandResult
      validate_recovery_nonce!(nonce)
      new_matches = fabric_table.all_fabrics.select do |candidate|
        candidate.node_id == node_id && candidate.fabric_id == fabric_id &&
          candidate.root_public_key == root_public_key
      end
      old_matches = fabric_table.all_fabrics.select do |candidate|
        candidate.node_id == node_id && candidate.fabric_id == old_fabric_id &&
          candidate.root_public_key == old_root_public_key
      end
      if new_matches.size != 1 || old_matches.size != 1 ||
         new_matches.first.fabric_index == old_matches.first.fabric_index ||
         @anchor_role || !@joint_fabric_provisioned
        raise Matter::AuthenticationError.new("Participant old and new fabrics are not available for cross-sign recovery")
      end
      new_fabric = new_matches.first
      old_fabric = old_matches.first
      verify_durable_anchor_old_credential!(new_fabric)
      verify_durable_anchor_old_credential!(old_fabric)
      certificate = persisted_icac ||
                    raise Matter::StorageError.new("Participant old cross-signed ICAC is absent")
      binding_document = persistence.app_document(APP_FABRIC_BINDING_DOCUMENT) ||
                         raise Matter::StorageError.new("Participant fabric binding is absent")
      role_document = persistence.app_document(APP_ROLE_DOCUMENT) ||
                      raise Matter::StorageError.new("Participant role is absent")
      role = JointFabricRoleState.from_document(role_document)
      durable_administrator = durable_transfer_administrator(ANCHOR_JFA_ENDPOINT_ID)
      durable_datastore = durable_transfer_datastore
      valid_old_binding = !role.anchor? && !role.transfer_complete? &&
                          FabricBindingState.from_document(binding_document).matches?(old_fabric) &&
                          joined_icac_matches_fabric?(certificate, old_fabric) &&
                          !joined_icac_matches_fabric?(certificate, new_fabric) &&
                          joint_fabric_service.try(&.cross_signed_icac) == certificate &&
                          joint_fabric_administrator.administrator_fabric_index == old_fabric.fabric_index &&
                          durable_administrator.administrator_fabric_index == old_fabric.fabric_index &&
                          joint_fabric_datastore.joint_fabric_index == old_fabric.fabric_index &&
                          joint_fabric_datastore.save_state == durable_datastore.save_state
      unless valid_old_binding
        raise Matter::AuthenticationError.new("Participant old JFA binding or ICAC changed during cross-sign recovery")
      end
      CommandResult.new("ok", nonce: nonce,
        inspected_cross_signed_icac: certificate,
        inspected_no_committed_cross_sign: true,
        inspected_fabric_id: new_fabric.fabric_id,
        inspected_root_public_key: new_fabric.root_public_key,
        inspected_old_fabric_id: old_fabric.fabric_id,
        inspected_old_root_public_key: old_fabric.root_public_key,
        inspected_node_id: node_id,
        inspected_administrator_fabric_index: new_fabric.fabric_index,
        inspected_old_administrator_fabric_index: old_fabric.fabric_index,
        inspected_jfa_endpoint_id: ANCHOR_JFA_ENDPOINT_ID,
        inspected_failsafe_clear: true,
        inspected_credential_journal_clear: true)
    end

    private def validate_recovery_nonce!(nonce : String?) : Nil
      unless nonce && nonce.size == ROTATION_NONCE_HEX_LENGTH && nonce.matches?(/\A[0-9a-fA-F]+\z/)
        raise Matter::ConfigurationError.new("A 32-byte hexadecimal recovery nonce is required")
      end
    end

    # The inspection file is an opt-in authenticated host channel to C. An
    # independent participant without an equivalent trusted witness remains
    # at CrossSigning; ordinary Matter attributes cannot prove durable AddICAC.
    private def reconcile_follow_up_cross_signed(target_node_id : UInt64, nonce : String?,
                                                 no_effect : Bool = false) : Nil
      validate_recovery_nonce!(nonce)
      proof_path = ENV["MATTER_JFA_FOLLOW_UP_INSPECTION_PATH"]? ||
                   raise Matter::ConfigurationError.new("Participant commit inspection channel is unavailable")
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Promoted Anchor fabric is unavailable")
      unless @anchor_role && @joint_fabric_provisioned
        raise Matter::AuthenticationError.new("Only the promoted Anchor can reconcile participant follow-up")
      end
      old_fabrics = fabric_table.all_fabrics.select do |fabric|
        fabric.root_public_key != own_fabric.root_public_key &&
          fabric.cats.any?(&.identity_value.==(ADMINISTRATOR_CAT_ID))
      end
      unless old_fabrics.size == 1
        raise Matter::ConfigurationError.new("Promoted Anchor must retain exactly one old Joint Fabric")
      end
      old_fabric = old_fabrics.first
      transfer_document = persistence.app_document(APP_TRANSFER_DOCUMENT) ||
                          raise Matter::ConfigurationError.new("Anchor transfer journal is absent")
      transfer = Matter::Controller::AnchorTransfer::Journal.from_document(transfer_document)
      unless transfer.stage.following_up? && transfer.candidate_node_id == old_fabric.node_id
        raise Matter::ConfigurationError.new("Anchor transfer is not awaiting participant follow-up")
      end
      document_name = "#{APP_FOLLOW_UP_PREFIX}#{target_node_id.to_s(16)}"
      follow_up_document = persistence.app_document(document_name) ||
                           raise Matter::ConfigurationError.new("Participant follow-up journal is absent")
      journal = Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal.from_document(follow_up_document)
      pending_icac = journal.pending_icac
      unless journal.stage.cross_signing? && journal.target_node_id == target_node_id &&
             target_node_id != own_fabric.node_id && target_node_id != old_fabric.node_id
        raise Matter::ConfigurationError.new("Participant follow-up is not awaiting cross-sign reconciliation")
      end
      if !no_effect && !pending_icac
        raise Matter::ConfigurationError.new("Participant follow-up has no pending ICAC")
      end
      durable_fabric = verify_durable_anchor_old_credential!(own_fabric)
      verify_promotion_bindings!(durable_fabric)
      verify_promotion_roles!
      durable_datastore = durable_transfer_datastore
      unless joint_fabric_datastore.save_state == durable_datastore.save_state &&
             durable_datastore.status.state.committed? &&
             joint_fabric_datastore.joint_fabric_index == own_fabric.fabric_index &&
             durable_datastore.anchor_root_ca == own_fabric.root_cert &&
             durable_datastore.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Promoted Anchor Datastore is not durably bound")
      end
      admins = durable_datastore.admin_list.select(&.node_id.==(target_node_id))
      unless admins.size == 1 && (!no_effect ? admins.first.icac == pending_icac : (!pending_icac || admins.first.icac != pending_icac))
        raise Matter::AuthenticationError.new("Promoted Anchor Administrator record cannot prove cross-sign outcome")
      end
      backend = Matter::Storage::YamlFile.new(proof_path)
      backend.open
      proof = begin
        result = backend.read(COMMAND_RPC_COLLECTION, "result") ||
                 raise Matter::ConfigurationError.new("Participant commit inspection result is absent")
        CommandResult.from_document(result)
      ensure
        backend.close if backend.open?
      end
      scanner = Matter::Controller::Scanner.new
      client = leased_case_client(own_fabric.node_id)
      begin
        scanner.start
        scanner.query_operational
        controller_store = @controller_store || raise Matter::ConfigurationError.new("Anchor controller identity is unavailable")
        identity = controller_store.load.fabric_for(own_fabric.fabric_id, own_fabric.root_public_key,
          own_fabric.node_id)
        peer = resolve_transfer_peer(scanner, identity.compressed_fabric_id, target_node_id)
        session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, identity,
          peer_node_id: target_node_id)
        im = Matter::Controller::ImClient.new(client)
        endpoint = Matter::Controller::JointCommissioning.discover_administrator_endpoint(im, session, peer)
        participant_index = remote_fabric_index(im, session, peer, own_fabric)
        verified = if no_effect
                     old_index = remote_fabric_index(im, session, peer, old_fabric)
                     proof.proves_uncommitted_cross_sign?(nonce.as(String), admins.first.icac,
                       own_fabric, old_fabric, target_node_id, endpoint, participant_index, old_index)
                   else
                     proof.proves_committed_cross_sign?(nonce.as(String), pending_icac.as(Bytes),
                       own_fabric, target_node_id, endpoint, participant_index)
                   end
        unless endpoint == ANCHOR_JFA_ENDPOINT_ID && verified
          raise Matter::AuthenticationError.new("Participant cross-sign witness does not match the pending transfer")
        end
        follow_up_administrators(joint_fabric_datastore, old_fabric, scanner, client, im,
          reconcile_target_node_id: target_node_id, reconcile_no_effect: no_effect)
      ensure
        client.close
        scanner.close
      end
    end

    # The console command records Anchor-side consent. An outgoing JFA must
    # also be listed in MATTER_JFA_CONSENTED_REMOVALS after its own user has
    # approved removal. The list contains comma-separated hexadecimal Node IDs.
    private def remove_administrator(outgoing_node_id : UInt64,
                                     interrupt_after_remove_fabric : Bool = false,
                                     interrupt_after_remove_admin : Bool = false,
                                     interrupt_after_anchor_rotation : Bool = false,
                                     interrupt_after_participant_rotation : Bool = false,
                                     interrupt_before_remove_admin : Bool = false,
                                     interrupt_before_anchor_noc : Bool = false,
                                     interrupt_before_participant_noc : Bool = false) : Nil
      raise Matter::ConfigurationError.new("Another Joint Fabric operation is running") if @removal_in_progress || @transfer_in_progress
      raise Matter::ConfigurationError.new("This device is not the Anchor") unless @anchor_role
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      bootstrap = provisioned_anchor_bootstrap(own_fabric)
      datastore = joint_fabric_datastore
      remaining = datastore.admin_list.map(&.node_id).reject do |id|
        id == own_fabric.node_id || id == outgoing_node_id
      end
      consented = ENV["MATTER_JFA_CONSENTED_REMOVALS"]?.to_s.split(',').any? do |value|
        value.strip.to_u64?(16) == outgoing_node_id
      end
      unless consented
        raise Matter::CommissioningError.new("Outgoing Administrator user consent is not recorded")
      end
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      journal = if document = persistence.app_document(document_name)
                  Matter::Controller::AdministratorRemoval::Journal.from_document(document)
                else
                  Matter::Controller::AdministratorRemoval::Journal.new(outgoing_node_id)
                end
      return if journal.stage.completed?
      if journal.stage.ready? && journal.fabric_id.nil? &&
         journal.root_public_key.nil? && journal.anchor_node_id.nil?
        journal.fabric_id = own_fabric.fabric_id
        journal.root_public_key = own_fabric.root_public_key
        journal.anchor_node_id = own_fabric.node_id
        journal.anchor_pre_rotation_noc = own_fabric.operational_cert.dup
        persistence.write_app_document(document_name, journal.to_document)
        persistence.flush
      end
      unless journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another Anchor fabric")
      end
      if journal.stage.ready?
        if old_noc = journal.anchor_pre_rotation_noc
          unless old_noc == own_fabric.operational_cert
            raise Matter::AuthenticationError.new("Anchor NOC changed since removal was prepared")
          end
        else
          journal.anchor_pre_rotation_noc = own_fabric.operational_cert.dup
          persistence.write_app_document(document_name, journal.to_document)
          persistence.flush
        end
      end
      if journal.administrator_cat_version.nil?
        unless journal.stage.ready?
          raise Matter::CommissioningError.new("Interrupted removal lacks its CAT version; reconcile before retry")
        end
        journal.administrator_cat_version = next_transfer_cat_version(datastore, ADMINISTRATOR_CAT_ID)
        persistence.write_app_document(document_name, journal.to_document)
        persistence.flush
      end
      admin_version = journal.administrator_cat_version.as(UInt16)
      scanner = Matter::Controller::Scanner.new
      controller_store = @controller_store || raise Matter::ConfigurationError.new("Anchor controller identity is unavailable")
      identity = controller_store.load.fabric_for(own_fabric.fabric_id, own_fabric.root_public_key, own_fabric.node_id)
      client = leased_case_client(own_fabric.node_id)
      im = Matter::Controller::ImClient.new(client)
      @removal_in_progress = true
      begin
        scanner.start
        scanner.query_operational
        outgoing_peer = nil.as(Socket::IPAddress?)
        outgoing_session = nil.as(Matter::Session::SecureContext?)
        if journal.stage.ready?
          outgoing_peer = resolve_transfer_peer(scanner, identity.compressed_fabric_id, outgoing_node_id)
          ::Log.for("matter.example.joint_fabric_administrator").info do
            "Administrator removal CASE pairing with outgoing node 0x#{outgoing_node_id.to_s(16)}"
          end
          outgoing_session = Matter::Controller::Pairing::CasePairing.new.pair(client, outgoing_peer,
            identity, peer_node_id: outgoing_node_id)
        end
        anchor_version = datastore.group_list.find(&.group_cat.==(ANCHOR_CAT_ID)).try(&.group_cat_version) ||
                         raise Matter::ConfigurationError.new("Anchor CAT group is unavailable")
        port = Matter::Controller::AdministratorRemoval::ImPort.new(im, outgoing_session,
          outgoing_peer, own_fabric.fabric_id, own_fabric.root_public_key, outgoing_node_id,
          datastore, -> {
          raise Matter::StorageError.new("Could not persist Administrator removal") unless persistence.save_cluster(datastore)
          persistence.flush
          nil
        },
          -> {
            groups = datastore.group_list.map do |group|
              group.group_cat_version = admin_version if group.group_cat == ADMINISTRATOR_CAT_ID
              group
            end
            datastore.group_list = groups
            update_datastore_administrator_acl_version(datastore, admin_version)
            raise Matter::StorageError.new("Could not persist Administrator CAT version") unless persistence.save_cluster(datastore)
            persistence.flush
            if interrupt_before_anchor_noc
              raise Matter::TransportError.new("Injected interruption before Anchor UpdateNOC")
            end
            self_peer = Socket::IPAddress.new("127.0.0.1", self.port)
            ::Log.for("matter.example.joint_fabric_administrator").info do
              "Administrator removal CASE pairing with local Anchor before NOC rotation"
            end
            self_session = Matter::Controller::Pairing::CasePairing.new.pair(client, self_peer,
              identity, peer_node_id: own_fabric.node_id)
            Matter::Controller::AnchorTransfer::AdministratorRotation.new(client, im,
              self_session, self_peer, own_fabric.node_id, bootstrap, admin_version,
              anchor_version, anchor_target: true, existing_fabric: true,
              existing_fabric_index: own_fabric.fabric_index).transition!
            configure_propagator(own_fabric, own_fabric.root_cert.as(Bytes))
            active_identity = controller_store.load.fabric_for(own_fabric.fabric_id,
              own_fabric.root_public_key, own_fabric.node_id)
            ::Log.for("matter.example.joint_fabric_administrator").info do
              "Administrator removal CASE pairing with local Anchor after NOC rotation"
            end
            active_session = Matter::Controller::Pairing::CasePairing.new.pair(client, self_peer,
              active_identity, peer_node_id: own_fabric.node_id)
            tighten_administrator_acl(im, active_session, self_peer, admin_version)
            nil
          },
          ->(node_id : UInt64) {
            active_identity = controller_store.load.fabric_for(own_fabric.fabric_id,
              own_fabric.root_public_key, own_fabric.node_id)
            active_bootstrap = Matter::Controller::JointCommissioning::AnchorBootstrap.new(
              active_identity, bootstrap.anchor_icac_private_key)
            peer = resolve_transfer_peer(scanner, active_identity.compressed_fabric_id, node_id)
            ::Log.for("matter.example.joint_fabric_administrator").info do
              "Administrator removal CASE pairing with participant 0x#{node_id.to_s(16)} before NOC rotation"
            end
            session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer,
              active_identity, peer_node_id: node_id)
            index = remote_fabric_index(im, session, peer, own_fabric)
            Matter::Controller::AnchorTransfer::AdministratorRotation.new(client, im,
              session, peer, node_id, active_bootstrap, admin_version, anchor_version,
              existing_fabric: true, existing_fabric_index: index).transition!
            ::Log.for("matter.example.joint_fabric_administrator").info do
              "Administrator removal CASE pairing with participant 0x#{node_id.to_s(16)} after NOC rotation"
            end
            refreshed_session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer,
              active_identity, peer_node_id: node_id)
            tighten_administrator_acl(im, refreshed_session, peer, admin_version)
            nil
          })
        effective_port = if interrupt_after_remove_fabric || interrupt_after_remove_admin || interrupt_before_remove_admin ||
                            interrupt_after_anchor_rotation || interrupt_after_participant_rotation ||
                            interrupt_before_participant_noc
                           InterruptedRemovalPort.new(port, interrupt_after_remove_fabric,
                             interrupt_after_remove_admin, interrupt_after_anchor_rotation,
                             interrupt_after_participant_rotation, interrupt_before_remove_admin,
                             interrupt_before_participant_noc)
                         else
                           port
                         end
        workflow = Matter::Controller::AdministratorRemoval::Workflow.new(datastore,
          own_fabric.node_id, remaining, effective_port, -> { true }, -> { consented },
          ->(state : Matter::Controller::AdministratorRemoval::Journal) {
            persistence.write_app_document(document_name, state.to_document)
            persistence.flush
            nil
          }, journal, ->(node_id : UInt64) {
          prior_version = journal.prior_administrator_cat_version ||
                          raise Matter::ConfigurationError.new("Removal journal lacks the prior Administrator CAT")
          active_identity = controller_store.load.fabric_for(own_fabric.fabric_id,
            own_fabric.root_public_key, own_fabric.node_id)
          peer = resolve_transfer_peer(scanner, active_identity.compressed_fabric_id, node_id)
          session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer,
            active_identity, peer_node_id: node_id)
          Matter::Controller::AdministratorRemoval::RotationInspection.capture_pre_rotation_credential!(
            im, session, peer, own_fabric.root_cert.as(Bytes), own_fabric.fabric_id,
            own_fabric.root_public_key, node_id, prior_version,
            Matter::Crypto::StandardCrypto.new.random_bytes(Matter::Controller::VidVerification::CHALLENGE_SIZE))
        })
        workflow.run
      ensure
        @removal_in_progress = false
        client.close
        scanner.close
      end
    end

    private def reconcile_fabric_removed(outgoing_node_id : UInt64, nonce : String?) : Nil
      raise Matter::ConfigurationError.new("Inspection nonce is required") if nonce.nil? || nonce.empty?
      proof_path = ENV["MATTER_JFA_OUTGOING_INSPECTION_PATH"]? ||
                   raise Matter::ConfigurationError.new("Outgoing inspection channel is unavailable")
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      backend = Matter::Storage::YamlFile.new(proof_path)
      backend.open
      proof = begin
        document = backend.read(COMMAND_RPC_COLLECTION, "result") ||
                   raise Matter::ConfigurationError.new("Outgoing inspection result is absent")
        CommandResult.from_document(document)
      ensure
        backend.close if backend.open?
      end
      unless proof.status == "ok" && proof.fabric_present == false &&
             proof.inspected_fabric_id == own_fabric.fabric_id &&
             proof.inspected_root_public_key == own_fabric.root_public_key &&
             proof.nonce == nonce
        raise Matter::AuthenticationError.new("Outgoing inspection did not prove the selected fabric was removed")
      end
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      document = persistence.app_document(document_name) ||
                 raise Matter::ConfigurationError.new("Administrator removal journal is absent")
      journal = Matter::Controller::AdministratorRemoval::Journal.from_document(document)
      unless journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another Anchor fabric")
      end
      unless journal.stage.removing_fabric? && journal.outgoing_node_id == outgoing_node_id
        raise Matter::ConfigurationError.new("Administrator removal is not awaiting fabric-removal reconciliation")
      end
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_journal!(journal,
        Matter::Controller::AdministratorRemoval::Stage::FabricRemoved,
        ->(state : Matter::Controller::AdministratorRemoval::Journal) {
          persistence.write_app_document(document_name, state.to_document)
          persistence.flush
          nil
        })
    end

    # The old Anchor's private transfer journal is an opt-in host witness. It
    # is carried through a trusted local command channel, not a Matter wire
    # attribute. An independent Anchor needs its own trusted witness source.
    private def inspect_transfer_requester(requester_node_id : UInt64, nonce : String?) : CommandResult
      raise Matter::ConfigurationError.new("Inspection nonce is required") if nonce.nil? || nonce.empty?
      fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Old Anchor fabric is unavailable")
      document = persistence.app_document(APP_TRANSFER_WATCH_DOCUMENT) ||
                 raise Matter::ConfigurationError.new("Anchor transfer requester journal is absent")
      watch = TransferWatchState.from_document(document)
      if persisted_transfer_complete? || !joint_fabric_datastore.status.state.delete_pending? ||
         watch.requester_node_id != requester_node_id ||
         watch.old_fabric_id != fabric.fabric_id ||
         watch.old_root_public_key != fabric.root_public_key
        raise Matter::AuthenticationError.new("Old Anchor cannot witness this transfer requester")
      end
      CommandResult.new("ok", inspected_node_id: fabric.node_id,
        inspected_fabric_id: fabric.fabric_id,
        inspected_root_public_key: fabric.root_public_key,
        inspected_transfer_requester_node_id: watch.requester_node_id,
        inspected_transfer_frozen: true, nonce: nonce)
    end

    private def reconcile_transfer_requested(old_anchor_node_id : UInt64, nonce : String?) : Nil
      raise Matter::ConfigurationError.new("Inspection nonce is required") if nonce.nil? || nonce.empty?
      proof_path = ENV["MATTER_JFA_OUTGOING_INSPECTION_PATH"]? ||
                   raise Matter::ConfigurationError.new("Old Anchor inspection channel is unavailable")
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Candidate Anchor fabric is unavailable")
      old_fabrics = fabric_table.all_fabrics.select do |fabric|
        fabric.root_public_key != own_fabric.root_public_key &&
          fabric.cats.any?(&.identity_value.==(ADMINISTRATOR_CAT_ID))
      end
      unless old_fabrics.size == 1
        raise Matter::ConfigurationError.new("Candidate must have exactly one joined Joint Fabric")
      end
      old_fabric = old_fabrics.first
      document = persistence.app_document(APP_TRANSFER_DOCUMENT) ||
                 raise Matter::ConfigurationError.new("Anchor transfer journal is absent")
      journal = Matter::Controller::AnchorTransfer::Journal.from_document(document)
      unless journal.stage.requesting? && journal.candidate_node_id == old_fabric.node_id
        raise Matter::ConfigurationError.new("Anchor transfer is not awaiting requester reconciliation")
      end
      backend = Matter::Storage::YamlFile.new(proof_path)
      backend.open
      proof = begin
        result = backend.read(COMMAND_RPC_COLLECTION, "result") ||
                 raise Matter::ConfigurationError.new("Old Anchor inspection result is absent")
        CommandResult.from_document(result)
      ensure
        backend.close if backend.open?
      end
      unless proof.status == "ok" && proof.nonce == nonce &&
             proof.inspected_transfer_frozen == true &&
             proof.inspected_transfer_requester_node_id == journal.candidate_node_id &&
             proof.inspected_node_id == old_anchor_node_id &&
             proof.inspected_fabric_id == old_fabric.fabric_id &&
             proof.inspected_root_public_key == old_fabric.root_public_key
        raise Matter::AuthenticationError.new("Old Anchor witness does not match the pending transfer")
      end
      Matter::Controller::AnchorTransfer::Workflow.reconcile_request_journal!(journal,
        Datastore::DatastoreStateEnum::DeletePending,
        ->(state : Matter::Controller::AnchorTransfer::Journal) {
          persistence.write_app_document(APP_TRANSFER_DOCUMENT, state.to_document)
          persistence.flush
          nil
        }, proof.inspected_transfer_requester_node_id)
    end

    # Local host witness for a lost Complete response. A sealed, provisioned
    # host channel must carry this result; the inactive Matter Datastore stays
    # inaccessible even to the former requester.
    private def inspect_transfer_completion(requester_node_id : UInt64, nonce : String?) : CommandResult
      raise Matter::ConfigurationError.new("Inspection nonce is required") if nonce.nil? || nonce.empty?
      fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Old Anchor fabric is unavailable")
      document = persistence.app_document(APP_TRANSFER_WATCH_DOCUMENT) ||
                 raise Matter::ConfigurationError.new("Anchor transfer requester journal is absent")
      watch = TransferWatchState.from_document(document)
      new_anchor_node_id = watch.new_anchor_node_id
      unless persisted_transfer_complete? && joint_fabric_datastore.status.state.delete_pending? &&
             joint_fabric_datastore.access_mode.inactive? &&
             watch.requester_node_id == requester_node_id &&
             watch.old_fabric_id == fabric.fabric_id &&
             watch.old_root_public_key == fabric.root_public_key &&
             new_anchor_node_id && new_anchor_node_id == configured_new_anchor_node_id(requester_node_id)
        raise Matter::AuthenticationError.new("Old Anchor cannot witness this transfer completion")
      end
      CommandResult.new("ok", inspected_node_id: fabric.node_id,
        inspected_fabric_id: fabric.fabric_id,
        inspected_root_public_key: fabric.root_public_key,
        inspected_transfer_requester_node_id: watch.requester_node_id,
        inspected_new_anchor_node_id: new_anchor_node_id,
        inspected_transfer_complete: true, nonce: nonce)
    end

    # The proof file is an opt-in trusted local channel. Its result is checked
    # again by the reusable journal helper before any stage change is saved.
    private def reconcile_transfer_complete(old_anchor_node_id : UInt64, nonce : String?) : Nil
      raise Matter::ConfigurationError.new("Inspection nonce is required") if nonce.nil? || nonce.empty?
      proof_path = ENV["MATTER_JFA_OUTGOING_INSPECTION_PATH"]? ||
                   raise Matter::ConfigurationError.new("Old Anchor inspection channel is unavailable")
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Candidate Anchor fabric is unavailable")
      old_fabrics = fabric_table.all_fabrics.select do |fabric|
        fabric.root_public_key != own_fabric.root_public_key &&
          fabric.cats.any?(&.identity_value.==(ADMINISTRATOR_CAT_ID))
      end
      unless old_fabrics.size == 1
        raise Matter::ConfigurationError.new("Candidate must have exactly one joined Joint Fabric")
      end
      old_fabric = old_fabrics.first
      document = persistence.app_document(APP_TRANSFER_DOCUMENT) ||
                 raise Matter::ConfigurationError.new("Anchor transfer journal is absent")
      journal = Matter::Controller::AnchorTransfer::Journal.from_document(document)
      unless journal.stage.completing? && journal.candidate_node_id == old_fabric.node_id
        raise Matter::ConfigurationError.new("Anchor transfer is not awaiting completion reconciliation")
      end
      backend = Matter::Storage::YamlFile.new(proof_path)
      backend.open
      proof = begin
        result = backend.read(COMMAND_RPC_COLLECTION, "result") ||
                 raise Matter::ConfigurationError.new("Old Anchor inspection result is absent")
        CommandResult.from_document(result)
      ensure
        backend.close if backend.open?
      end
      unless proof.status == "ok" && proof.nonce == nonce &&
             proof.inspected_transfer_complete == true &&
             proof.inspected_node_id && proof.inspected_fabric_id &&
             proof.inspected_root_public_key && proof.inspected_transfer_requester_node_id &&
             proof.inspected_new_anchor_node_id
        raise Matter::AuthenticationError.new("Old Anchor completion witness is incomplete")
      end
      witness = Matter::Controller::AnchorTransfer::CompletionWitness.new(
        proof.nonce.as(String), proof.inspected_node_id.as(UInt64),
        proof.inspected_fabric_id.as(UInt64), proof.inspected_root_public_key.as(Bytes),
        proof.inspected_transfer_requester_node_id.as(UInt64),
        proof.inspected_new_anchor_node_id.as(UInt64), proof.inspected_transfer_complete.as(Bool))
      Matter::Controller::AnchorTransfer::Workflow.reconcile_completion_journal!(journal,
        witness,
        ->(state : Matter::Controller::AnchorTransfer::Journal) {
          persistence.write_app_document(APP_TRANSFER_DOCUMENT, state.to_document)
          persistence.flush
          nil
        }, nonce.as(String), old_anchor_node_id, old_fabric.fabric_id,
        old_fabric.root_public_key, own_fabric.node_id)
    end

    private def reconcile_datastore_removed(outgoing_node_id : UInt64) : Nil
      raise Matter::ConfigurationError.new("This device is not the Anchor") unless @anchor_role
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      datastore = joint_fabric_datastore
      unless datastore.anchor_node_id == own_fabric.node_id &&
             datastore.joint_fabric_index == own_fabric.fabric_index
        raise Matter::AuthenticationError.new("Datastore belongs to another Anchor")
      end
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      document = persistence.app_document(document_name) ||
                 raise Matter::ConfigurationError.new("Administrator removal journal is absent")
      journal = Matter::Controller::AdministratorRemoval::Journal.from_document(document)
      unless journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id &&
             journal.outgoing_node_id == outgoing_node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another Anchor fabric")
      end
      persisted = persistence.backend.read(Matter::Storage::Collections::CLUSTERS, datastore.persistence_key) ||
                  raise Matter::StorageError.new("Anchor Datastore has no durable record")
      durable_datastore = Datastore.new(Matter::DataType::EndpointNumber.new(ANCHOR_JFA_ENDPOINT_ID))
      durable_datastore.restore_state(persisted)
      unless datastore.save_state == durable_datastore.save_state
        raise Matter::CommissioningError.new("Anchor Datastore differs from its durable record")
      end
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_removed!(journal, datastore,
        own_fabric.fabric_index,
        ->(state : Matter::Controller::AdministratorRemoval::Journal) {
          persistence.write_app_document(document_name, state.to_document)
          persistence.flush
          nil
        })
    end

    private def reconcile_datastore_no_effect(outgoing_node_id : UInt64) : Nil
      raise Matter::ConfigurationError.new("This device is not the Anchor") unless @anchor_role
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      datastore = joint_fabric_datastore
      unless datastore.anchor_node_id == own_fabric.node_id &&
             datastore.joint_fabric_index == own_fabric.fabric_index
        raise Matter::AuthenticationError.new("Datastore belongs to another Anchor")
      end
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      document = persistence.app_document(document_name) ||
                 raise Matter::ConfigurationError.new("Administrator removal journal is absent")
      journal = Matter::Controller::AdministratorRemoval::Journal.from_document(document)
      unless journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id &&
             journal.outgoing_node_id == outgoing_node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another Anchor fabric")
      end
      persisted = persistence.backend.read(Matter::Storage::Collections::CLUSTERS, datastore.persistence_key) ||
                  raise Matter::StorageError.new("Anchor Datastore has no durable record")
      durable_datastore = Datastore.new(Matter::DataType::EndpointNumber.new(ANCHOR_JFA_ENDPOINT_ID))
      durable_datastore.restore_state(persisted)
      unless datastore.save_state == durable_datastore.save_state
        raise Matter::CommissioningError.new("Anchor Datastore differs from its durable record")
      end
      durable_datastore.joint_fabric_index = own_fabric.fabric_index
      Matter::Controller::AdministratorRemoval::Workflow.reconcile_datastore_no_effect!(journal, durable_datastore,
        own_fabric.fabric_index,
        ->(state : Matter::Controller::AdministratorRemoval::Journal) {
          persistence.write_app_document(document_name, state.to_document)
          persistence.flush
          nil
        })
    end

    # UpdateNOC may never have started even though the Datastore CAT and ACL
    # were saved. A signed old-NOC proof is usable only after the local
    # fail-safe has ended and the durable credential undo journal is clear.
    private def reconcile_anchor_rotation_no_effect(outgoing_node_id : UInt64, nonce : String?) : Nil
      raise Matter::ConfigurationError.new("This device is not the Anchor") unless @anchor_role
      unless nonce && nonce.size == ROTATION_NONCE_HEX_LENGTH && nonce.matches?(/\A[0-9a-fA-F]+\z/)
        raise Matter::ConfigurationError.new("A 32-byte hexadecimal rotation nonce is required")
      end
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      root_certificate = own_fabric.root_cert || raise Matter::ConfigurationError.new("Anchor root is unavailable")
      datastore = joint_fabric_datastore
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      document = persistence.app_document(document_name) ||
                 raise Matter::ConfigurationError.new("Administrator removal journal is absent")
      journal = Matter::Controller::AdministratorRemoval::Journal.from_document(document)
      unless journal.stage.rotating_anchor? && journal.outgoing_node_id == outgoing_node_id &&
             journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another Anchor rotation")
      end
      prior_version = journal.prior_administrator_cat_version ||
                      raise Matter::ConfigurationError.new("Removal journal has no prior CAT version")
      old_noc = journal.anchor_pre_rotation_noc ||
                raise Matter::ConfigurationError.new("Removal journal has no pre-rotation Anchor NOC")
      anchor_version = datastore.group_list.find(&.group_cat.==(ANCHOR_CAT_ID)).try(&.group_cat_version) ||
                       raise Matter::ConfigurationError.new("Removal Datastore has no Anchor CAT version")
      durable_fabric = verify_durable_anchor_old_credential!(own_fabric)
      unless durable_fabric.operational_cert == old_noc
        raise Matter::AuthenticationError.new("Anchor NOC differs from the journaled pre-rotation certificate")
      end
      verify_durable_anchor_rotation_datastore!(datastore)

      client = leased_case_client(own_fabric.node_id)
      begin
        controller_store = @controller_store || raise Matter::ConfigurationError.new("Anchor controller identity is unavailable")
        identity = controller_store.load.fabric_for(own_fabric.fabric_id, own_fabric.root_public_key,
          own_fabric.node_id)
        peer = Socket::IPAddress.new("127.0.0.1", port)
        session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, identity,
          peer_node_id: own_fabric.node_id)
        im = Matter::Controller::ImClient.new(client)
        Matter::Controller::AdministratorRemoval::RotationInspection.verify_no_effect!(im, session,
          peer, root_certificate, own_fabric.fabric_id, own_fabric.root_public_key,
          own_fabric.node_id, prior_version, nonce.hexbytes, old_noc,
          anchor_cat_version: anchor_version)

        finalize_anchor_rotation_no_effect!(journal, datastore, own_fabric, old_noc, document_name)
      ensure
        client.close
      end
    end

    private def finalize_anchor_rotation_no_effect!(journal : Matter::Controller::AdministratorRemoval::Journal,
                                                    datastore : Datastore, own_fabric : Matter::Fabric,
                                                    old_noc : Bytes, document_name : String) : Nil
      # Inbound CASE commands run under this same reentrant registry lock. Keep
      # ArmFailSafe/UpdateNOC/CommissioningComplete outside the final state
      # check and the potentially yielding durable journal write. The remote
      # CASE proof has already returned before acquiring the lock.
      @message_handler.registry.synchronize do
        current = verify_durable_anchor_old_credential!(own_fabric)
        unless current.operational_cert == old_noc
          raise Matter::AuthenticationError.new("Anchor NOC changed during no-effect inspection")
        end
        verify_durable_anchor_rotation_datastore!(datastore)
        Matter::Controller::AdministratorRemoval::Workflow.reconcile_anchor_rotation_no_effect!(
          journal, datastore, own_fabric.fabric_index,
          ->(state : Matter::Controller::AdministratorRemoval::Journal) {
            persistence.write_app_document(document_name, state.to_document)
            persistence.flush
            nil
          })
      end
    end

    private def verify_durable_anchor_old_credential!(fabric : Matter::Fabric) : Matter::Fabric
      unless persistence.backend.durable?
        raise Matter::StorageError.new("Anchor rotation recovery requires durable storage")
      end
      # An expired timer can stop reporting armed before its rollback fiber
      # clears the context. Do not lease across that pending callback.
      if general_commissioning.failsafe_context ||
         persistence.backend.read(Matter::Commissioning::CredentialJournal::COLLECTION,
           Matter::Commissioning::CredentialJournal::ID)
        raise Matter::CommissioningError.new("Anchor credential rotation may still be provisional")
      end
      live = fabric_table.get_fabric(fabric.fabric_index) ||
             raise Matter::AuthenticationError.new("Anchor fabric is absent")
      document = persistence.backend.read(Matter::FabricTable::COLLECTION, fabric.fabric_index.to_s) ||
                 raise Matter::StorageError.new("Anchor fabric has no durable record")
      durable = Matter::Fabric.from_document(document)
      unless durable.fabric_id == fabric.fabric_id && durable.root_public_key == fabric.root_public_key &&
             durable.node_id == fabric.node_id && durable.fabric_index == fabric.fabric_index &&
             live.fabric_id == durable.fabric_id && live.root_public_key == durable.root_public_key &&
             live.node_id == durable.node_id && live.fabric_index == durable.fabric_index &&
             live.operational_cert == durable.operational_cert &&
             live.intermediate_cert == durable.intermediate_cert &&
             live.operational_public_key == durable.operational_public_key &&
             live.operational_private_key == durable.operational_private_key &&
             live.cats == durable.cats && fabric.operational_cert == durable.operational_cert &&
             Matter::Crypto::MatterCertificate.public_key_from_tlv(durable.operational_cert) ==
               durable.operational_public_key
        raise Matter::AuthenticationError.new("Anchor live and durable credentials differ")
      end
      durable
    end

    private def verify_durable_anchor_rotation_datastore!(datastore : Datastore) : Nil
      document = persistence.backend.read(Matter::Storage::Collections::CLUSTERS, datastore.persistence_key) ||
                 raise Matter::StorageError.new("Anchor Datastore has no durable record")
      durable = Datastore.new(Matter::DataType::EndpointNumber.new(ANCHOR_JFA_ENDPOINT_ID))
      durable.restore_state(document)
      unless datastore.save_state == durable.save_state
        raise Matter::CommissioningError.new("Anchor Datastore differs from its durable record")
      end
    end

    # This result is valid only over a host-authenticated private channel.
    # The nonce provides freshness; Matter wire attributes cannot report a
    # participant's fail-safe and credential undo journal state.
    private def inspect_participant_rotation_no_effect(node_id : UInt64, fabric_id : UInt64?,
                                                       root_public_key : Bytes?, nonce : String?) : CommandResult
      validate_recovery_nonce!(nonce)
      matches = fabric_table.all_fabrics.select do |candidate|
        candidate.node_id == node_id && candidate.fabric_id == fabric_id &&
          candidate.root_public_key == root_public_key
      end
      if matches.size != 1 || @anchor_role || !@joint_fabric_provisioned
        raise Matter::AuthenticationError.new("Participant does not own the selected joined fabric")
      end
      fabric = matches.first
      durable = verify_durable_anchor_old_credential!(fabric)
      binding_document = persistence.app_document(APP_FABRIC_BINDING_DOCUMENT) ||
                         raise Matter::StorageError.new("Participant fabric binding is absent")
      role_document = persistence.app_document(APP_ROLE_DOCUMENT) ||
                      raise Matter::StorageError.new("Participant role is absent")
      role = JointFabricRoleState.from_document(role_document)
      administrator = durable_transfer_administrator(ANCHOR_JFA_ENDPOINT_ID)
      if role.anchor? || role.transfer_complete? ||
         !FabricBindingState.from_document(binding_document).matches?(durable) ||
         joint_fabric_administrator.administrator_fabric_index != durable.fabric_index ||
         administrator.administrator_fabric_index != durable.fabric_index ||
         joint_fabric_datastore.joint_fabric_index != durable.fabric_index
        raise Matter::AuthenticationError.new("Participant endpoint or role differs from durable fabric")
      end
      credential = Matter::Cluster::OperationalCredentials::Tlv::NOC.new(
        durable.operational_cert, durable.intermediate_cert, durable.fabric_index).to_slice
      CommandResult.new("ok", nonce: nonce, inspected_fabric_id: durable.fabric_id,
        inspected_root_public_key: durable.root_public_key, inspected_node_id: durable.node_id,
        inspected_administrator_fabric_index: durable.fabric_index,
        inspected_jfa_endpoint_id: ANCHOR_JFA_ENDPOINT_ID,
        inspected_operational_credential: credential,
        inspected_failsafe_clear: true, inspected_credential_journal_clear: true)
    end

    private def validate_recovery_lease_id!(lease_id : String) : Nil
      unless lease_id.size == ROTATION_NONCE_HEX_LENGTH && lease_id.matches?(/\A[0-9a-fA-F]+\z/)
        raise Matter::ConfigurationError.new("A 32-byte hexadecimal participant recovery lease ID is required")
      end
    end

    private def participant_recovery_fence_for(request : CommandRequest) : ParticipantRecoveryFence
      lease_id = request.recovery_lease_id ||
                 raise Matter::ConfigurationError.new("Participant recovery lease ID is required")
      validate_recovery_lease_id!(lease_id)
      anchor_node_id = request.recovery_anchor_node_id ||
                       raise Matter::ConfigurationError.new("Recovery Anchor Node ID is required")
      outgoing_node_id = request.recovery_outgoing_node_id ||
                         raise Matter::ConfigurationError.new("Recovery outgoing Node ID is required")
      fabric_id = request.fabric_id || raise Matter::ConfigurationError.new("Recovery Fabric ID is required")
      root_public_key = request.root_public_key ||
                        raise Matter::ConfigurationError.new("Recovery root public key is required")
      credential = request.recovery_credential ||
                   raise Matter::ConfigurationError.new("Recovery credential is required")
      if !Matter::DataType::NodeId.valid_joint_fabric?(anchor_node_id) ||
         !Matter::DataType::NodeId.valid_joint_fabric?(outgoing_node_id) ||
         !Matter::DataType::NodeId.valid_joint_fabric?(request.node_id) ||
         anchor_node_id == request.node_id || outgoing_node_id == request.node_id ||
         root_public_key.empty? || credential.empty?
        raise Matter::ConfigurationError.new("Invalid participant recovery binding")
      end
      ParticipantRecoveryFence.new(lease_id, anchor_node_id, outgoing_node_id,
        request.node_id, fabric_id, root_public_key, credential)
    end

    # The host-authenticated private channel identifies B. A's caller supplies
    # the durable journal binding and a fresh nonce. The protocol lock excludes
    # inbound Matter mutations while C checks and durably installs this fence.
    private def acquire_participant_recovery_fence(request : CommandRequest) : CommandResult
      candidate = participant_recovery_fence_for(request)
      @host_credential_exchange_lock.synchronize do
        @message_handler.registry.synchronize do
          if @participant_recovery_fence_uncertain
            raise Matter::StorageError.new("Participant recovery fence persistence is uncertain")
          end
          if existing = @participant_recovery_fence
            unless existing.same_request?(candidate)
              raise Matter::AuthenticationError.new("A different participant recovery fence is active")
            end
          else
            if released_document = persistence.app_document(APP_PARTICIPANT_RECOVERY_RELEASE)
              released = ParticipantRecoveryFence.from_document(released_document)
              if released.lease_id == candidate.lease_id
                raise Matter::AuthenticationError.new("Participant recovery lease ID was already released")
              end
            end
          end
          proof = inspect_participant_rotation_no_effect(request.node_id,
            request.fabric_id, request.root_public_key, request.nonce)
          unless proof.inspected_operational_credential == candidate.credential
            raise Matter::AuthenticationError.new("Participant credential differs from recovery fence")
          end
          unless @participant_recovery_fence
            @participant_recovery_fence_uncertain = true
            persistence.write_app_document(APP_PARTICIPANT_RECOVERY_FENCE, candidate.to_document)
            persistence.flush
            @participant_recovery_fence = candidate
            @participant_recovery_fence_uncertain = false
          end
          CommandResult.new("ok", nonce: request.nonce,
            inspected_fabric_id: proof.inspected_fabric_id,
            inspected_root_public_key: proof.inspected_root_public_key,
            inspected_node_id: proof.inspected_node_id,
            inspected_administrator_fabric_index: proof.inspected_administrator_fabric_index,
            inspected_jfa_endpoint_id: proof.inspected_jfa_endpoint_id,
            inspected_operational_credential: proof.inspected_operational_credential,
            inspected_failsafe_clear: proof.inspected_failsafe_clear,
            inspected_credential_journal_clear: proof.inspected_credential_journal_clear,
            inspected_recovery_lease_id: candidate.lease_id)
        end
      end
    end

    private def release_participant_recovery_fence(request : CommandRequest) : CommandResult
      candidate = participant_recovery_fence_for(request)
      validate_recovery_nonce!(request.nonce)
      @message_handler.registry.synchronize do
        if @participant_recovery_fence_uncertain
          raise Matter::StorageError.new("Participant recovery fence persistence is uncertain")
        end
        if existing = @participant_recovery_fence
          unless existing.same_request?(candidate)
            raise Matter::AuthenticationError.new("Participant recovery release binding differs")
          end
          proof = inspect_participant_rotation_no_effect(request.node_id,
            request.fabric_id, request.root_public_key, request.nonce)
          unless proof.inspected_operational_credential == candidate.credential
            raise Matter::AuthenticationError.new("Participant credential changed before recovery release")
          end
          @participant_recovery_fence_uncertain = true
          persistence.write_app_document(APP_PARTICIPANT_RECOVERY_RELEASE, candidate.to_document)
          persistence.flush
          persistence.delete_app_document(APP_PARTICIPANT_RECOVERY_FENCE)
          persistence.flush
          @participant_recovery_fence = nil
          @participant_recovery_fence_uncertain = false
        else
          released_document = persistence.app_document(APP_PARTICIPANT_RECOVERY_RELEASE) ||
                              raise Matter::AuthenticationError.new("Participant recovery lease was never acquired")
          released = ParticipantRecoveryFence.from_document(released_document)
          unless released.same_request?(candidate)
            raise Matter::AuthenticationError.new("Participant recovery release binding differs")
          end
        end
        CommandResult.new("ok", nonce: request.nonce)
      end
    end

    private def reconcile_participant_rotation_no_effect(outgoing_node_id : UInt64,
                                                         nonce : String?,
                                                         interrupt_before_rewind_save : Bool = false,
                                                         interrupt_after_rewind_save : Bool = false) : Nil
      raise Matter::ConfigurationError.new("This device is not the Anchor") unless @anchor_role
      validate_recovery_nonce!(nonce)
      proof_path = ENV["MATTER_JFA_FOLLOW_UP_INSPECTION_PATH"]? ||
                   raise Matter::ConfigurationError.new("Participant inspection channel is unavailable")
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      root_certificate = own_fabric.root_cert || raise Matter::ConfigurationError.new("Anchor root is unavailable")
      datastore = joint_fabric_datastore
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      document = persistence.app_document(document_name) ||
                 raise Matter::ConfigurationError.new("Administrator removal journal is absent")
      journal = Matter::Controller::AdministratorRemoval::Journal.from_document(document)
      target_node_id = journal.active_node_id || begin
        # After a durable no-effect rewind the active ID is cleared. The
        # retained credential and lease still identify the only unfinished
        # participant in the frozen AdminList ordering.
        participants = datastore.admin_list.map(&.node_id).reject(&.==(journal.anchor_node_id))
        participants[journal.rotated_nodes.size]?
      end || raise Matter::ConfigurationError.new("Participant rotation has no active Node ID")
      credential = journal.participant_pre_rotation_credential ||
                   raise Matter::ConfigurationError.new("Participant rotation lacks a pre-rotation credential")
      prior_version = journal.prior_administrator_cat_version ||
                      raise Matter::ConfigurationError.new("Removal journal has no prior CAT version")
      unless (journal.stage.rotating_participant? ||
             (journal.stage.anchor_rotated? && journal.participant_recovery_lease_id)) &&
             journal.outgoing_node_id == outgoing_node_id &&
             journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another participant rotation")
      end
      if journal.stage.anchor_rotated?
        verify_durable_anchor_old_credential!(own_fabric)
        verify_durable_anchor_rotation_datastore!(datastore)
        if journal.remaining_admin_entries != datastore.admin_list.map(&.to_slice) ||
           journal.rotated_nodes.includes?(target_node_id)
          raise Matter::AuthenticationError.new("Participant recovery release AdminList differs from frozen journal")
        end
        release_participant_recovery_after_rewind!(proof_path, document_name, journal,
          own_fabric, target_node_id, credential)
        return
      end
      verify_durable_anchor_old_credential!(own_fabric)
      verify_durable_anchor_rotation_datastore!(datastore)
      proof = if lease_id = journal.participant_recovery_lease_id
                # The C command file can contain a later status or release
                # result after B crashes. Obtain a new witness for the same
                # caller nonce before repeating the signed CASE check.
                request_participant_recovery_command!(proof_path,
                  "inspect-participant-rotation-no-effect", target_node_id, own_fabric,
                  outgoing_node_id, credential, lease_id, nonce.as(String))
              else
                backend = Matter::Storage::YamlFile.new(proof_path)
                backend.open
                begin
                  result = backend.read(COMMAND_RPC_COLLECTION, "result") ||
                           raise Matter::ConfigurationError.new("Participant inspection result is absent")
                  CommandResult.from_document(result)
                ensure
                  backend.close if backend.open?
                end
              end
      scanner = Matter::Controller::Scanner.new
      controller_store = @controller_store || raise Matter::ConfigurationError.new("Anchor controller identity is unavailable")
      identity = controller_store.load.fabric_for(own_fabric.fabric_id,
        own_fabric.root_public_key, own_fabric.node_id)
      client = leased_case_client(own_fabric.node_id)
      begin
        scanner.start
        scanner.query_operational
        peer = resolve_transfer_peer(scanner, identity.compressed_fabric_id, target_node_id)
        session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, identity,
          peer_node_id: target_node_id)
        im = Matter::Controller::ImClient.new(client)
        participant_index = remote_fabric_index(im, session, peer, own_fabric)
        unless proof.proves_participant_rotation_no_effect?(nonce.as(String), credential,
                 own_fabric, target_node_id, participant_index)
          raise Matter::AuthenticationError.new("Participant no-effect witness differs from pending rotation")
        end
        Matter::Controller::AdministratorRemoval::RotationInspection.verify_participant_no_effect!(
          im, session, peer, root_certificate, own_fabric.fabric_id, own_fabric.root_public_key,
          target_node_id, prior_version, nonce.as(String).hexbytes, credential)
        # Persist the recovery lease ID before asking C to lock its credential
        # state and return a fresh witness under that lock.
        lease_id = journal.participant_recovery_lease_id || Matter::Crypto::StandardCrypto.new.random_bytes(
          Matter::Controller::VidVerification::CHALLENGE_SIZE).hexstring
        unless journal.participant_recovery_lease_id
          leased = journal.detached_copy
          leased.participant_recovery_lease_id = lease_id
          @message_handler.registry.synchronize do
            persistence.write_app_document(document_name, leased.to_document)
            persistence.flush
          end
          journal = leased
        end
        fresh_nonce = Matter::Crypto::StandardCrypto.new.random_bytes(
          Matter::Controller::VidVerification::CHALLENGE_SIZE).hexstring
        fresh_proof = request_participant_recovery_command!(proof_path,
          "acquire-participant-recovery-fence", target_node_id, own_fabric,
          outgoing_node_id, credential, lease_id, fresh_nonce)
        unless fresh_proof.proves_participant_rotation_no_effect?(fresh_nonce,
                 credential, own_fabric, target_node_id, participant_index) &&
               fresh_proof.inspected_recovery_lease_id == lease_id
          raise Matter::AuthenticationError.new("Fresh participant witness differs from pending rotation")
        end
        @message_handler.registry.synchronize do
          verify_durable_anchor_old_credential!(own_fabric)
          verify_durable_anchor_rotation_datastore!(datastore)
          if interrupt_before_rewind_save
            raise Matter::StorageError.new("Injected interruption before participant rewind save")
          end
          Matter::Controller::AdministratorRemoval::Workflow.reconcile_participant_rotation_no_effect!(
            journal, datastore, own_fabric.fabric_index,
            fresh_proof.inspected_operational_credential.as(Bytes),
            ->(state : Matter::Controller::AdministratorRemoval::Journal) {
              persistence.write_app_document(document_name, state.to_document)
              persistence.flush
              if interrupt_after_rewind_save
                raise Matter::StorageError.new("Injected lost participant rewind save acknowledgement")
              end
              nil
            })
        end
        release_participant_recovery_after_rewind!(proof_path, document_name, journal,
          own_fabric, target_node_id, credential)
      ensure
        client.close
        scanner.close
      end
    end

    private def request_participant_recovery_command!(proof_path : String,
                                                      operation : String,
                                                      target_node_id : UInt64,
                                                      fabric : Matter::Fabric,
                                                      outgoing_node_id : UInt64,
                                                      credential : Bytes,
                                                      lease_id : String,
                                                      nonce : String) : CommandResult
      File.delete?(proof_path)
      backend = Matter::Storage::YamlFile.new(proof_path)
      backend.open
      begin
        request = CommandRequest.new(operation,
          target_node_id, fabric.fabric_id, fabric.root_public_key, nonce,
          recovery_lease_id: lease_id, recovery_outgoing_node_id: outgoing_node_id,
          recovery_anchor_node_id: fabric.node_id, recovery_credential: credential)
        backend.write(COMMAND_RPC_COLLECTION, "request", request.to_document)
      ensure
        backend.close if backend.open?
      end
      deadline = Time.instant + PARTICIPANT_WITNESS_TIMEOUT
      loop do
        result_store = Matter::Storage::YamlFile.new(proof_path)
        result_store.open
        result = begin
          document = result_store.read(COMMAND_RPC_COLLECTION, "result")
          document.try { |value| CommandResult.from_document(value) }
        ensure
          result_store.close if result_store.open?
        end
        return result if result && result.status != "in-progress"
        if Time.instant >= deadline
          raise Matter::TimeoutError.new("Fresh participant no-effect witness timed out")
        end
        sleep 200.milliseconds
      end
    end

    private def release_participant_recovery_after_rewind!(proof_path : String,
                                                           document_name : String,
                                                           journal : Matter::Controller::AdministratorRemoval::Journal,
                                                           fabric : Matter::Fabric,
                                                           target_node_id : UInt64,
                                                           credential : Bytes) : Nil
      lease_id = journal.participant_recovery_lease_id ||
                 raise Matter::ConfigurationError.new("Participant recovery lease ID is absent")
      fresh_nonce = Matter::Crypto::StandardCrypto.new.random_bytes(
        Matter::Controller::VidVerification::CHALLENGE_SIZE).hexstring
      response = request_participant_recovery_command!(proof_path,
        "release-participant-recovery-fence", target_node_id, fabric,
        journal.outgoing_node_id, credential, lease_id, fresh_nonce)
      unless response.status == "ok" && response.nonce == fresh_nonce
        raise Matter::AuthenticationError.new("Participant recovery fence release failed: #{response.error}")
      end
      @message_handler.registry.synchronize do
        current_document = persistence.app_document(document_name) ||
                           raise Matter::StorageError.new("Participant recovery journal disappeared")
        current = Matter::Controller::AdministratorRemoval::Journal.from_document(current_document)
        unless current.stage.anchor_rotated? && current.participant_recovery_lease_id == lease_id &&
               current.participant_pre_rotation_credential == credential
          raise Matter::AuthenticationError.new("Participant recovery journal changed before release")
        end
        released = current.detached_copy
        released.participant_recovery_lease_id = nil
        released.participant_pre_rotation_credential = nil
        persistence.write_app_document(document_name, released.to_document)
        persistence.flush
      end
    end

    # The nonce is supplied by the host performing recovery. A fresh CASE
    # session and signed OperationalCredentials response bind the observed NOC
    # to that nonce, the target Node ID, and this journal's fabric and CAT.
    private def reconcile_removal_rotation(outgoing_node_id : UInt64, nonce : String?,
                                           anchor : Bool) : Nil
      raise Matter::ConfigurationError.new("This device is not the Anchor") unless @anchor_role
      unless nonce && nonce.size == ROTATION_NONCE_HEX_LENGTH && nonce.matches?(/\A[0-9a-fA-F]+\z/)
        raise Matter::ConfigurationError.new("A 32-byte hexadecimal rotation nonce is required")
      end
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      root_certificate = own_fabric.root_cert || raise Matter::ConfigurationError.new("Anchor root is unavailable")
      datastore = joint_fabric_datastore
      unless datastore.status.state.committed? && datastore.anchor_node_id == own_fabric.node_id &&
             datastore.admin_list.none?(&.node_id.==(outgoing_node_id))
        raise Matter::AuthenticationError.new("Removal Datastore does not match pending rotation")
      end
      document_name = "#{APP_REMOVAL_PREFIX}#{outgoing_node_id.to_s(16)}"
      document = persistence.app_document(document_name) ||
                 raise Matter::ConfigurationError.new("Administrator removal journal is absent")
      journal = Matter::Controller::AdministratorRemoval::Journal.from_document(document)
      unless journal.fabric_id == own_fabric.fabric_id &&
             journal.root_public_key == own_fabric.root_public_key &&
             journal.anchor_node_id == own_fabric.node_id
        raise Matter::AuthenticationError.new("Removal journal belongs to another Anchor fabric")
      end
      stage = anchor ? Matter::Controller::AdministratorRemoval::Stage::RotatingAnchor : Matter::Controller::AdministratorRemoval::Stage::RotatingParticipant
      unless journal.stage == stage && journal.outgoing_node_id == outgoing_node_id
        raise Matter::ConfigurationError.new("Removal journal is not awaiting this rotation")
      end
      version = journal.administrator_cat_version ||
                raise Matter::ConfigurationError.new("Removal journal has no CAT version")
      anchor_version = if anchor
                         datastore.group_list.find(&.group_cat.==(ANCHOR_CAT_ID)).try(&.group_cat_version) ||
                           raise Matter::ConfigurationError.new("Removal Datastore has no Anchor CAT version")
                       end
      target_node_id = if anchor
                         raise Matter::ConfigurationError.new("Anchor rotation has an active participant") if journal.active_node_id
                         own_fabric.node_id
                       else
                         journal.active_node_id || raise Matter::ConfigurationError.new("Participant rotation has no active Node ID")
                       end
      if target_node_id == outgoing_node_id || journal.rotated_nodes.includes?(target_node_id) ||
         (!anchor && datastore.admin_list.none?(&.node_id.==(target_node_id)))
        raise Matter::AuthenticationError.new("Rotation target differs from pending Administrator")
      end
      scanner = Matter::Controller::Scanner.new
      controller_store = @controller_store || raise Matter::ConfigurationError.new("Anchor controller identity is unavailable")
      identity = controller_store.load.fabric_for(own_fabric.fabric_id, own_fabric.root_public_key, own_fabric.node_id)
      client = leased_case_client(own_fabric.node_id)
      begin
        scanner.start
        scanner.query_operational
        peer = anchor ? Socket::IPAddress.new("127.0.0.1", port) : resolve_transfer_peer(scanner, identity.compressed_fabric_id, target_node_id)
        session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer, identity,
          peer_node_id: target_node_id)
        im = Matter::Controller::ImClient.new(client)
        Matter::Controller::AdministratorRemoval::RotationInspection.verify_completed!(im, session,
          peer, root_certificate, own_fabric.fabric_id, own_fabric.root_public_key,
          target_node_id, version, nonce.hexbytes, anchor_cat_version: anchor_version)
        Matter::Controller::AdministratorRemoval::Workflow.reconcile_journal!(journal,
          Matter::Controller::AdministratorRemoval::Stage::AnchorRotated,
          ->(state : Matter::Controller::AdministratorRemoval::Journal) {
            persistence.write_app_document(document_name, state.to_document)
            persistence.flush
            nil
          }, rotated_node_id: anchor ? nil : target_node_id,
          participant_completed: anchor ? nil : true)
      ensure
        client.close
        scanner.close
      end
    end

    private def update_datastore_administrator_acl_version(datastore : Datastore,
                                                           version : UInt16) : Nil
      old_subject = ADMINISTRATOR_CAT_SUBJECT_PREFIX | (version - 1_u16).to_u64
      new_subject = ADMINISTRATOR_CAT_SUBJECT_PREFIX | version.to_u64
      entries = datastore.node_acl_list.map do |entry|
        if subjects = entry.acl_entry.subjects
          entry.acl_entry.subjects = subjects.map { |subject| subject == old_subject ? new_subject : subject }
        end
        entry
      end
      datastore.node_acl_list = entries
    end

    private def tighten_administrator_acl(im : Matter::Controller::ImClient,
                                          session : Matter::Session::SecureContext,
                                          peer : Socket::IPAddress, version : UInt16) : Nil
      old_subject = ADMINISTRATOR_CAT_SUBJECT_PREFIX | (version - 1_u16).to_u64
      new_subject = ADMINISTRATOR_CAT_SUBJECT_PREFIX | version.to_u64
      report = im.read_attribute(session, peer, Matter::Node::ROOT_ENDPOINT_ID,
        Matter::Cluster::AccessControl::CLUSTER_ID, Matter::Cluster::AccessControl::ATTR_ACL)
      data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
             raise Matter::ProtocolError.new("Administrator ACL read omitted data")
      entries = Array(Matter::Cluster::AccessControl::AccessControlEntry).from_tlv(data.to_slice)
      changed = false
      entries.each do |entry|
        subjects = entry.subjects
        next unless subjects && subjects.includes?(old_subject)
        entry.subjects = subjects.map { |subject| subject == old_subject ? new_subject : subject }
        changed = true
      end
      return unless changed
      response = im.write_attribute(session, peer, Matter::Node::ROOT_ENDPOINT_ID,
        Matter::Cluster::AccessControl::CLUSTER_ID, Matter::Cluster::AccessControl::ATTR_ACL,
        entries.to_tlv)
      unless response.write_responses.any? { |item| item.status.status == Matter::InteractionModel::StatusCode::Success.value }
        raise Matter::CommissioningError.new("Administrator CAT ACL update failed")
      end
    end

    private def remote_fabric_index(im : Matter::Controller::ImClient,
                                    session : Matter::Session::SecureContext,
                                    peer : Socket::IPAddress,
                                    fabric : Matter::Fabric) : UInt8
      report = im.read_attribute(session, peer, Matter::Node::ROOT_ENDPOINT_ID,
        Matter::Cluster::OperationalCredentials::CLUSTER_ID,
        Matter::Cluster::OperationalCredentials::ATTR_FABRICS,
        fabric_filtered: false)
      data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data) ||
             raise Matter::ProtocolError.new("Administrator Fabrics read omitted data")
      descriptors = Array(Matter::Cluster::OperationalCredentials::Tlv::FabricDescriptor).from_tlv(data.to_slice)
      descriptor = descriptors.find do |item|
        item.fabric_id == fabric.fabric_id && item.root_public_key == fabric.root_public_key
      end
      descriptor.try(&.fabric_index) || raise Matter::AuthenticationError.new("Administrator is not on the selected Joint Fabric")
    end

    private def provisioned_anchor_bootstrap(fabric : Matter::Fabric) : Matter::Controller::JointCommissioning::AnchorBootstrap
      path = ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"]? ||
             raise Matter::ConfigurationError.new("Anchor bootstrap state path is required for transfer")
      backend = Matter::Storage::YamlFile.new(path)
      begin
        identity = Matter::Controller::StateStore.new(backend).load.fabrics.find do |candidate|
          candidate.fabric_id == fabric.fabric_id &&
            candidate.root_public_key == fabric.root_public_key
        end || raise Matter::ConfigurationError.new("Candidate Anchor bootstrap identity is missing")
        key = identity.intermediate_private_key ||
              raise Matter::ConfigurationError.new("Candidate Anchor ICAC key is missing")
        Matter::Controller::JointCommissioning::AnchorBootstrap.new(identity, key)
      ensure
        backend.close if backend.open?
      end
    end

    private def next_transfer_cat_version(store : Datastore, cat : UInt16) : UInt16
      current = store.group_list.find(&.group_cat.==(cat)).try(&.group_cat_version) ||
                raise Matter::ConfigurationError.new("Source Datastore lacks CAT group 0x#{cat.to_s(16)}")
      raise Matter::ConfigurationError.new("CAT version exhausted") if current == UInt16::MAX
      current + 1_u16
    end

    private def process_anchor_exchange_request : Nil
      path = ENV["MATTER_JFA_JCM_REQUEST_PATH"]?
      return unless path && File.exists?(path)
      backend = Matter::Storage::YamlFile.new(path)
      backend.open
      begin
        return if backend.read(JCM_RPC_COLLECTION, JCM_RPC_RESULT)
        document = backend.read(JCM_RPC_COLLECTION, JCM_RPC_REQUEST)
        return unless document
        request = AnchorExchangeRequest.from_document(document)
        backend.write(JCM_RPC_COLLECTION, JCM_RPC_RESULT,
          AnchorExchangeResult.new("in-progress").to_document)
        backend.close
        result = begin
          @host_credential_exchange_lock.synchronize do
            reject_fenced_mutation!
            certificate = execute_anchor_exchange(request)
            AnchorExchangeResult.new("ok", certificate)
          end
        rescue ex
          ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Anchor ICAC exchange failed" }
          AnchorExchangeResult.new("error", error: ex.message)
        end
        backend.open
        backend.write(JCM_RPC_COLLECTION, JCM_RPC_RESULT, result.to_document)
      ensure
        backend.close if backend.open?
      end
    rescue ex : Matter::Error | IO::Error | ArgumentError
      ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Anchor exchange request failed" }
    end

    private def process_command_request : Nil
      path = ENV["MATTER_JFA_COMMAND_PATH"]?
      return unless path && File.exists?(path)
      backend = Matter::Storage::YamlFile.new(path)
      backend.open
      begin
        return if backend.read(COMMAND_RPC_COLLECTION, "result")
        document = backend.read(COMMAND_RPC_COLLECTION, "request")
        return unless document
        request = CommandRequest.from_document(document)
        backend.write(COMMAND_RPC_COLLECTION, "result", CommandResult.new("in-progress", nonce: request.nonce).to_document)
        backend.close
        result = begin
          if recovery_fenced? && !request.operation.in?("inspect-participant-rotation-no-effect",
               "inspect-participant-recovery-fence", "acquire-participant-recovery-fence",
               "release-participant-recovery-fence", "inspect-fabric")
            raise Matter::CommissioningError.new("Participant recovery fence blocks private mutation")
          end
          case request.operation
          when "transfer-anchor"
            transfer_anchor_from(request.node_id, request.interrupt_before_transfer_follow_up?,
              request.interrupt_after_first_transfer_follow_up?, request.interrupt_after_transfer_request?,
              request.interrupt_before_transfer_copy_journal?,
              request.interrupt_after_transfer_copy?, request.interrupt_after_transfer_rotation?,
              request.interrupt_after_first_transfer_administrator_rotation?,
              request.interrupt_after_second_transfer_administrator_rotation?,
              request.interrupt_after_transfer_promotion?,
              request.interrupt_after_transfer_complete?,
              request.interrupt_after_next_transfer_cross_sign?,
              request.interrupt_before_next_transfer_cross_sign_journal?,
              request.interrupt_before_next_transfer_pending_icac_journal?,
              interrupt_after_next_old_fabric_removed: request.interrupt_after_next_transfer_old_fabric_removed?)
            CommandResult.new("ok")
          when "remove-administrator"
            remove_administrator(request.node_id, request.interrupt_after_remove_fabric?,
              request.interrupt_after_remove_admin?, request.interrupt_after_anchor_rotation?,
              request.interrupt_after_participant_rotation?, request.interrupt_before_remove_admin?,
              request.interrupt_before_anchor_noc?, request.interrupt_before_participant_noc?)
            CommandResult.new("ok")
          when "inspect-fabric"
            fabric_id = request.fabric_id || raise Matter::ConfigurationError.new("Fabric ID is required")
            root_public_key = request.root_public_key || raise Matter::ConfigurationError.new("Root public key is required")
            present = fabric_table.all_fabrics.any? do |fabric|
              fabric.fabric_id == fabric_id && fabric.root_public_key == root_public_key
            end
            CommandResult.new("ok", fabric_present: present, inspected_fabric_id: fabric_id,
              inspected_root_public_key: root_public_key, nonce: request.nonce)
          when "set-test-datastore-friendly-name"
            name = request.test_friendly_name || raise Matter::ConfigurationError.new("Test name is required")
            fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
            root = fabric.root_cert || raise Matter::ConfigurationError.new("Anchor root is unavailable")
            datastore = joint_fabric_datastore
            unless @anchor_role && datastore.status.state.committed? &&
                   datastore.anchor_root_ca == root && datastore.anchor_node_id == fabric.node_id
              raise Matter::AuthenticationError.new("Only the active Anchor can set the test Datastore name")
            end
            unless datastore.configure_anchor(root, fabric.node_id, fabric.vendor_id, name).success? &&
                   persistence.save_cluster(datastore)
              raise Matter::StorageError.new("Could not persist test Datastore name")
            end
            persistence.flush
            CommandResult.new("ok")
          when "inspect-anchor-identity"
            fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
            root_certificate = fabric.root_cert || raise Matter::ConfigurationError.new("Anchor root is unavailable")
            icac_certificate = fabric.intermediate_cert || raise Matter::ConfigurationError.new("Anchor ICAC is unavailable")
            CommandResult.new("ok", fabric_present: @joint_fabric_provisioned,
              inspected_fabric_id: fabric.fabric_id, inspected_root_public_key: fabric.root_public_key,
              inspected_root_certificate: root_certificate, inspected_icac_certificate: icac_certificate,
              inspected_node_id: fabric.node_id, inspected_cross_signed_icac: persisted_icac,
              inspected_administrator_fabric_index: joint_fabric_administrator.administrator_fabric_index,
              inspected_fabric_count: fabric_table.all_fabrics.size,
              inspected_datastore_admin_entries: joint_fabric_datastore.admin_list.map(&.to_slice),
              nonce: request.nonce)
          when "inspect-cross-sign-commit"
            inspect_cross_sign_commit(request.node_id, request.fabric_id,
              request.root_public_key, request.nonce)
          when "inspect-cross-sign-no-effect"
            inspect_cross_sign_no_effect(request.node_id, request.fabric_id,
              request.root_public_key, request.old_fabric_id,
              request.old_root_public_key, request.nonce)
          when "inspect-participant-rotation-no-effect"
            inspect_participant_rotation_no_effect(request.node_id, request.fabric_id,
              request.root_public_key, request.nonce)
          when "inspect-participant-recovery-fence"
            CommandResult.new("ok", nonce: request.nonce,
              inspected_recovery_lease_id: @participant_recovery_fence.try(&.lease_id))
          when "acquire-participant-recovery-fence"
            acquire_participant_recovery_fence(request)
          when "release-participant-recovery-fence"
            release_participant_recovery_fence(request)
          when "inspect-new-anchor"
            CommandResult.new("ok", nonce: request.nonce,
              subscription_committed: @participant_view_current)
          when "set-test-fail-safe-max"
            seconds = request.fail_safe_max_seconds ||
                      raise Matter::ConfigurationError.new("Test fail-safe maximum is required")
            if seconds == 0_u16 ||
               seconds > Matter::Commissioning::FailsafeService::DEFAULT_MAX_CUMULATIVE_SECONDS ||
               general_commissioning.failsafe_armed?
              raise Matter::ConfigurationError.new("Invalid test fail-safe maximum or active fail-safe")
            end
            general_commissioning.max_cumulative_failsafe_seconds = seconds
            CommandResult.new("ok")
          when "inspect-transfer-requester"
            inspect_transfer_requester(request.node_id, request.nonce)
          when "reconcile-transfer-requested"
            reconcile_transfer_requested(request.node_id, request.nonce)
            CommandResult.new("ok")
          when "inspect-transfer-completion"
            inspect_transfer_completion(request.node_id, request.nonce)
          when "reconcile-transfer-complete"
            reconcile_transfer_complete(request.node_id, request.nonce)
            CommandResult.new("ok")
          when "reconcile-transfer-promoted"
            transfer_anchor_from(request.node_id, reconcile_promoting: true)
            CommandResult.new("ok")
          when "reconcile-transfer-copied"
            transfer_anchor_from(request.node_id, reconcile_copying: true)
            CommandResult.new("ok")
          when "reconcile-transfer-rotated-administrator"
            transfer_anchor_from(request.node_id, reconcile_rotating_administrator: true,
              reconciliation_nonce: request.nonce,
              reconciliation_target_node_id: request.rotation_target_node_id)
            CommandResult.new("ok")
          when "inspect-transfer-stage"
            document = persistence.app_document(APP_TRANSFER_DOCUMENT) ||
                       raise Matter::ConfigurationError.new("Anchor transfer journal is absent")
            journal = Matter::Controller::AnchorTransfer::Journal.from_document(document)
            CommandResult.new("ok", inspected_transfer_stage: journal.stage.value,
              inspected_active_rotation_node_id: journal.active_rotation_node_id)
          when "inspect-follow-up-stage"
            document = persistence.app_document("#{APP_FOLLOW_UP_PREFIX}#{request.node_id.to_s(16)}")
            stage = document.try do |entry|
              Matter::Controller::AnchorTransfer::AdministratorFollowUp::Journal.from_document(entry).stage.value
            end
            CommandResult.new("ok", inspected_follow_up_stage: stage)
          when "inspect-removal-stage"
            document = persistence.app_document("#{APP_REMOVAL_PREFIX}#{request.node_id.to_s(16)}") ||
                       raise Matter::ConfigurationError.new("Administrator removal journal is absent")
            journal = Matter::Controller::AdministratorRemoval::Journal.from_document(document)
            CommandResult.new("ok", inspected_removal_stage: journal.stage.value,
              inspected_removal_rotated_nodes: journal.rotated_nodes)
          when "reconcile-follow-up-cross-signed"
            reconcile_follow_up_cross_signed(request.node_id, request.nonce)
            CommandResult.new("ok", nonce: request.nonce)
          when "reconcile-follow-up-cross-sign-no-effect"
            reconcile_follow_up_cross_signed(request.node_id, request.nonce, no_effect: true)
            CommandResult.new("ok", nonce: request.nonce)
          when "inspect-device-migration-stage"
            stage = inspect_device_migration_stage(request)
            CommandResult.new("ok", inspected_migration_stage: stage.value)
          when "inspect-controller-migration-node"
            CommandResult.new("ok", inspected_controller_migration_node_present: inspect_controller_migration_node(request))
          when "reconcile-fabric-removed"
            reconcile_fabric_removed(request.node_id, request.nonce)
            CommandResult.new("ok")
          when "reconcile-datastore-removed"
            reconcile_datastore_removed(request.node_id)
            CommandResult.new("ok")
          when "reconcile-datastore-no-effect"
            reconcile_datastore_no_effect(request.node_id)
            CommandResult.new("ok")
          when "reconcile-anchor-rotated"
            reconcile_removal_rotation(request.node_id, request.nonce, true)
            CommandResult.new("ok", nonce: request.nonce)
          when "reconcile-anchor-rotation-no-effect"
            reconcile_anchor_rotation_no_effect(request.node_id, request.nonce)
            CommandResult.new("ok", nonce: request.nonce)
          when "reconcile-participant-rotated"
            reconcile_removal_rotation(request.node_id, request.nonce, false)
            CommandResult.new("ok", nonce: request.nonce)
          when "reconcile-participant-rotation-no-effect"
            reconcile_participant_rotation_no_effect(request.node_id, request.nonce,
              request.interrupt_before_participant_rewind_save?,
              request.interrupt_after_participant_rewind_save?)
            CommandResult.new("ok", nonce: request.nonce)
          when "finalize-commissioning"
            certificate = finalize_commissioning(request)
            CommandResult.new("ok", nonce: request.nonce, certificate: certificate)
          when "migrate-device", "reconcile-device-migration",
               "reconcile-device-migration-no-effect", "rollback-device-migration",
               "resume-rollback-device-migration", "resume-anchor-registration"
            migrate_device(request)
            CommandResult.new("ok", nonce: request.nonce)
          else
            raise Matter::ConfigurationError.new("Unknown Joint Fabric command")
          end
        rescue ex
          ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Joint Fabric command failed" }
          CommandResult.new("error", ex.message, nonce: request.nonce)
        end
        backend.open
        backend.write(COMMAND_RPC_COLLECTION, "result", result.to_document)
      ensure
        backend.close if backend.open?
      end
    rescue ex : Matter::Error | IO::Error | ArgumentError
      ::Log.for("matter.example.joint_fabric_administrator").error(exception: ex) { "Joint Fabric command request failed" }
    end

    # A local, consented command. Neither B's ICAC signing key nor A's joined
    # operational private key crosses the command channel.
    private def migrate_device(request : CommandRequest) : Nil
      require_migration_consent!(request.node_id)
      verifier = migration_attestation_verifier
      anchor_fabric_id = request.fabric_id || raise Matter::ConfigurationError.new("Anchor fabric ID is required")
      anchor_root = request.root_public_key || raise Matter::ConfigurationError.new("Anchor root public key is required")
      anchor_node_id = request.anchor_node_id || raise Matter::ConfigurationError.new("Anchor device Node ID is required")
      address = request.peer_address || raise Matter::ConfigurationError.new("Device address is required")
      target_peer = Socket::IPAddress.new(address, request.peer_port || 5540)
      old_device_fabric = fabric_table.all_fabrics.find do |fabric|
        provisioned_bootstrap_fabric?(fabric)
      end || raise Matter::ConfigurationError.new("Bootstrap Fabric B is not installed")
      joined_device_fabric = fabric_table.all_fabrics.find do |fabric|
        fabric.fabric_id == anchor_fabric_id && fabric.root_public_key == anchor_root
      end || raise Matter::ConfigurationError.new("Joined Anchor fabric is not installed")
      unless bootstrap_joint_fabric_datastore.joint_fabric_index == old_device_fabric.fabric_index &&
             bootstrap_joint_fabric_datastore.access_mode.active?
        raise Matter::ConfigurationError.new("Fabric B Datastore is unavailable")
      end
      bootstrap = provisioned_anchor_bootstrap(old_device_fabric).fabric
      old_fabric = migration_identity(old_device_fabric, bootstrap)
      anchor_fabric = migration_identity(joined_device_fabric)
      cross_icac = persisted_icac || raise Matter::ConfigurationError.new("Cross-signed ICAC is unavailable")
      issuer_key = bootstrap.intermediate_private_key ||
                   raise Matter::ConfigurationError.new("Fabric B ICAC signer is unavailable")
      issuer = Matter::Controller::JointFabricDeviceMigration.cross_signed_issuer(
        old_fabric, anchor_fabric, cross_icac, issuer_key)
      # The trusted Anchor Node ID is published by the provisioned controller
      # fixture. It is resolved to an address only after the identity is fixed.
      anchor_datastore_node_id = ENV["MATTER_JFA_ANCHOR_NODE_ID"]?.try(&.to_u64?(16)) ||
                                 raise Matter::ConfigurationError.new("Anchor Node ID is required")
      anchor_peer = configured_peer_hints[anchor_datastore_node_id]? ||
                    raise Matter::ConfigurationError.new("Anchor operational address is unavailable")
      admin_group = bootstrap_joint_fabric_datastore.group_list.find(&.group_cat.==(ADMINISTRATOR_CAT_ID)) ||
                    raise Matter::ConfigurationError.new("Fabric B Administrator CAT group is missing")
      admin_version = admin_group.group_cat_version ||
                      raise Matter::ConfigurationError.new("Fabric B Administrator CAT version is missing")
      admin_cat = Matter::DataType::CaseAuthenticatedTag.create(ADMINISTRATOR_CAT_ID, admin_version).value
      store = @controller_store || Matter::Controller::StateStore.new(persistence.backend)
      state = store.load
      [old_fabric, anchor_fabric].each do |identity|
        existing = state.fabrics.find do |fabric|
          fabric.fabric_id == identity.fabric_id &&
            fabric.root_public_key == identity.root_public_key &&
            fabric.controller_node_id == identity.controller_node_id
        end
        state.install_fabric(identity) unless existing
      end
      store.save(state)
      journal_store = Matter::Controller::JointFabricDeviceMigration::JournalStore.new(persistence.backend)
      stored_journal = journal_store.load(old_fabric.fabric_id, old_fabric.root_public_key,
        request.node_id, anchor_fabric.fabric_id, anchor_fabric.root_public_key,
        anchor_node_id)
      if request.operation != "migrate-device" && !stored_journal
        raise Matter::ConfigurationError.new("No device migration journal exists to recover")
      end
      journal = stored_journal || Matter::Controller::JointFabricDeviceMigration::Journal.new(
        old_fabric.fabric_id, anchor_fabric.fabric_id, request.node_id, anchor_node_id,
        old_fabric.root_public_key, anchor_fabric.root_public_key)
      local_peer = Socket::IPAddress.new("127.0.0.1", port)
      reply_loss_path = ENV["MATTER_JFA_MIGRATION_TEST_SDK_REPLY_LOSS_PATH"]?
      remove_reply_loss_path = ENV["MATTER_JFA_MIGRATION_TEST_SDK_REMOVE_REPLY_LOSS_PATH"]?
      migration_client = if reply_loss_path
                           SdkMigrationReplyLossClient.new(reply_loss_path, remove_reply_loss_path)
                         else
                           Matter::Controller::Client.new
                         end
      network = Matter::Controller::JointFabricDeviceMigration::NetworkPort.new(
        store, old_fabric, anchor_fabric, issuer, request.node_id, anchor_node_id,
        target_peer, old_device_fabric.node_id, local_peer, BOOTSTRAP_JFA_ENDPOINT_ID,
        anchor_datastore_node_id, anchor_peer, ANCHOR_JFA_ENDPOINT_ID, "Migrated device", admin_cat,
        verifier,
        commissioning_ack: -> {
          if request.interrupt_after_migration_complete_before_ack?
            raise Matter::TransportError.new("Injected interruption after device CommissioningComplete")
          end
          acknowledged = journal_store.load(old_fabric.fabric_id,
            old_fabric.root_public_key, request.node_id,
            anchor_fabric.fabric_id, anchor_fabric.root_public_key,
            anchor_node_id) ||
                         raise Matter::StorageError.new("Migration journal is missing at CommissioningComplete")
          acknowledged.commissioning_acknowledged = true
          journal_store.save(acknowledged)
        },
        fail_safe_deadline: ->(deadline : Int64, max_seconds : UInt16) {
          armed = journal_store.load(old_fabric.fabric_id,
            old_fabric.root_public_key, request.node_id,
            anchor_fabric.fabric_id, anchor_fabric.root_public_key,
            anchor_node_id) ||
                  raise Matter::StorageError.new("Migration journal is missing after ArmFailSafe")
          armed.fail_safe_deadline_unix = deadline
          armed.fail_safe_max_seconds = max_seconds
          journal_store.save(armed)
          if request.interrupt_after_migration_failsafe_recorded?
            raise Matter::TransportError.new("Injected interruption after migration fail-safe bound was saved")
          end
        },
        before_complete: -> {
          if request.interrupt_after_migration_add_noc_before_complete?
            raise Matter::TransportError.new("Injected interruption after device AddNOC before CommissioningComplete")
          end
        },
        anchor_registration_committed: -> {
          if request.interrupt_after_migration_anchor_node_committed?
            raise Matter::TransportError.new("Injected interruption after Anchor NodeList committed")
          end
        },
        anchor_node_removed: -> {
          if request.interrupt_after_migration_anchor_node_removed?
            raise Matter::TransportError.new("Injected interruption after Anchor RemoveNode")
          end
        },
        anchor_fabric_removed: -> {
          if request.interrupt_after_migration_anchor_fabric_removed?
            raise Matter::TransportError.new("Injected interruption after Anchor RemoveFabric")
          end
        },
        old_fabric_removed: -> {
          if request.interrupt_after_migration_old_fabric_removed?
            raise Matter::TransportError.new("Injected interruption after device RemoveFabric")
          end
        },
        old_node_removed: -> {
          if request.interrupt_after_migration_old_node_removed?
            raise Matter::TransportError.new("Injected interruption after Datastore RemoveNode")
          end
        },
        timeout: 30.seconds, client: migration_client)
      begin
        workflow = Matter::Controller::JointFabricDeviceMigration::Workflow.new(
          journal, network, -> { true },
          ->(entry : Matter::Controller::JointFabricDeviceMigration::Journal) {
            journal_store.save(entry)
            if request.interrupt_before_migration_anchor_verified? && entry.stage.verifying_anchor?
              raise Matter::TransportError.new("Injected interruption before Anchor verification")
            end
            if request.interrupt_before_migration_old_fabric_removed? && entry.stage.removing_old_fabric?
              raise Matter::TransportError.new("Injected interruption before device RemoveFabric")
            end
            if request.interrupt_before_migration_old_node_removed? && entry.stage.removing_old_node?
              raise Matter::TransportError.new("Injected interruption before Fabric B RemoveNode")
            end
          })
        case request.operation
        when "migrate-device"
          workflow.run
        when "rollback-device-migration"
          workflow.rollback!
        when "resume-rollback-device-migration"
          workflow.resume_rollback!
        when "resume-anchor-registration"
          workflow.resume_anchor_registration!
        when "reconcile-device-migration-no-effect"
          workflow.reconcile_no_effect!
        when "reconcile-device-migration"
          stage = case workflow.journal.stage
                  when Matter::Controller::JointFabricDeviceMigration::Stage::CommissioningAnchor
                    Matter::Controller::JointFabricDeviceMigration::Stage::AnchorCommissioned
                  when Matter::Controller::JointFabricDeviceMigration::Stage::VerifyingAnchor
                    Matter::Controller::JointFabricDeviceMigration::Stage::AnchorVerified
                  when Matter::Controller::JointFabricDeviceMigration::Stage::AddingAnchorNode
                    Matter::Controller::JointFabricDeviceMigration::Stage::AnchorNodeAdded
                  when Matter::Controller::JointFabricDeviceMigration::Stage::RemovingOldFabric
                    Matter::Controller::JointFabricDeviceMigration::Stage::OldFabricRemoved
                  when Matter::Controller::JointFabricDeviceMigration::Stage::RemovingOldNode
                    Matter::Controller::JointFabricDeviceMigration::Stage::Complete
                  when Matter::Controller::JointFabricDeviceMigration::Stage::RollingBack
                    Matter::Controller::JointFabricDeviceMigration::Stage::RolledBack
                  when Matter::Controller::JointFabricDeviceMigration::Stage::Complete
                    Matter::Controller::JointFabricDeviceMigration::Stage::Complete
                  when Matter::Controller::JointFabricDeviceMigration::Stage::RolledBack
                    Matter::Controller::JointFabricDeviceMigration::Stage::RolledBack
                  else
                    raise Matter::ConfigurationError.new("Migration journal does not need reconciliation")
                  end
          workflow.reconcile!(stage)
        end
      ensure
        network.close
      end
    end

    private def inspect_device_migration_stage(request : CommandRequest) : Matter::Controller::JointFabricDeviceMigration::Stage
      require_migration_consent!(request.node_id)
      anchor_fabric_id = request.fabric_id || raise Matter::ConfigurationError.new("Anchor fabric ID is required")
      anchor_root = request.root_public_key || raise Matter::ConfigurationError.new("Anchor root public key is required")
      anchor_node_id = request.anchor_node_id || raise Matter::ConfigurationError.new("Anchor device Node ID is required")
      old_device_fabric = fabric_table.all_fabrics.find do |fabric|
        provisioned_bootstrap_fabric?(fabric)
      end || raise Matter::ConfigurationError.new("Bootstrap Fabric B is not installed")
      joined_device_fabric = fabric_table.all_fabrics.find do |fabric|
        fabric.fabric_id == anchor_fabric_id && fabric.root_public_key == anchor_root
      end || raise Matter::ConfigurationError.new("Joined Anchor fabric is not installed")
      journal_store = Matter::Controller::JointFabricDeviceMigration::JournalStore.new(persistence.backend)
      journal = journal_store.load(old_device_fabric.fabric_id, old_device_fabric.root_public_key,
        request.node_id, joined_device_fabric.fabric_id, joined_device_fabric.root_public_key,
        anchor_node_id) || raise Matter::ConfigurationError.new("Device migration journal is absent")
      journal.stage
    end

    private def inspect_controller_migration_node(request : CommandRequest) : Bool
      require_migration_consent!(request.node_id)
      anchor_fabric_id = request.fabric_id || raise Matter::ConfigurationError.new("Anchor fabric ID is required")
      anchor_root = request.root_public_key || raise Matter::ConfigurationError.new("Anchor root public key is required")
      anchor_node_id = request.anchor_node_id || raise Matter::ConfigurationError.new("Anchor device Node ID is required")
      joined = fabric_table.all_fabrics.find do |fabric|
        fabric.fabric_id == anchor_fabric_id && fabric.root_public_key == anchor_root
      end || raise Matter::ConfigurationError.new("Joined Anchor fabric is not installed")
      store = @controller_store || Matter::Controller::StateStore.new(persistence.backend)
      store.load.nodes_for(anchor_fabric_id, anchor_root, joined.node_id).has_key?(anchor_node_id)
    end

    private def require_migration_consent!(node_id : UInt64) : Nil
      allowed = ENV["MATTER_JFA_CONSENTED_MIGRATIONS"]?.to_s.split(',').any? do |id|
        id.to_u64?(16) == node_id
      end
      raise Matter::CommissioningError.new("Device migration consent is missing") unless allowed
    end

    private def migration_identity(fabric : Matter::Fabric,
                                   bootstrap : Matter::Controller::FabricInfo? = nil) : Matter::Controller::FabricInfo
      root = fabric.root_cert || raise Matter::ConfigurationError.new("Migration fabric root is unavailable")
      Matter::Controller::FabricInfo.new(
        fabric_id: fabric.fabric_id,
        controller_node_id: fabric.node_id,
        ipk_value: fabric.ipk,
        root_cert: root,
        root_public_key: fabric.root_public_key,
        controller_noc: fabric.operational_cert,
        controller_private_key: fabric.operational_private_key,
        root_private_key: bootstrap.try(&.root_private_key),
        admin_vendor_id: fabric.vendor_id,
        intermediate_cert: fabric.intermediate_cert,
        intermediate_private_key: bootstrap.try(&.intermediate_private_key),
        ipk_epoch_keys: fabric.ipk_epoch_keys
      )
    end

    private def provisioned_bootstrap_fabric?(fabric : Matter::Fabric) : Bool
      provisioned_anchor_bootstrap(fabric)
      true
    rescue Matter::ConfigurationError
      false
    end

    private def finalize_commissioning(request : CommandRequest) : Bytes?
      raise Matter::ConfigurationError.new("Finalization requires a target Node ID") if request.node_id == Matter::DataType::NodeId::UNSPECIFIED
      nonce = request.nonce
      raise Matter::ConfigurationError.new("Finalization nonce is required") if nonce.nil? || nonce.empty?
      jcm_parameters = joint_handoff_parameters(request) if request.jcm?
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor fabric is unavailable")
      unless @anchor_role && has_anchor_cat?(own_fabric)
        raise Matter::AuthenticationError.new("Device is not the active Anchor")
      end
      unless request.fabric_id == own_fabric.fabric_id && request.root_public_key == own_fabric.root_public_key
        raise Matter::AuthenticationError.new("Finalization requested for a different fabric")
      end
      store = @controller_store || raise Matter::ConfigurationError.new("Anchor controller identity is unavailable")
      identity = store.load.fabric_for(own_fabric.fabric_id, own_fabric.root_public_key, own_fabric.node_id)
      unless identity.controller_node_id == own_fabric.node_id && identity.controller_noc == own_fabric.operational_cert
        raise Matter::AuthenticationError.new("Anchor CASE identity does not match its operational fabric")
      end
      if jcm_parameters && identity.root_private_key.nil?
        raise Matter::ConfigurationError.new("JCM Anchor signing requires a local root issuer")
      end

      scanner = Matter::Controller::Scanner.new
      client = leased_case_client(own_fabric.node_id)
      cross_signed_icac = nil
      begin
        scanner.start
        scanner.query_operational
        peer = resolve_transfer_peer(scanner, identity.compressed_fabric_id, request.node_id)
        if parameters = jcm_parameters
          public_key, endpoint = parameters
          anchor_icac = identity.intermediate_cert ||
                        raise Matter::ConfigurationError.new("Anchor ICAC is unavailable")
          icac_id = Matter::Crypto::MatterCertificate.from_slice(anchor_icac).subject.icac_id ||
                    raise Matter::ConfigurationError.new("Anchor ICAC ID is unavailable")
          exchange_request = AnchorExchangeRequest.new(identity.fabric_id, identity.root_public_key,
            request.node_id, peer, endpoint, public_key, icac_id)
          cross_signed_icac = execute_anchor_exchange(exchange_request)
          Matter::Controller::JointCommissioning.validate_cross_signed_icac(
            cross_signed_icac, identity, public_key, icac_id)
        end
        session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer,
          identity, peer_node_id: request.node_id)
        response = Matter::Controller::ImClient.new(client, 45.seconds).invoke(
          session: session, peer: peer, endpoint_id: Matter::Node::ROOT_ENDPOINT_ID,
          cluster_id: Matter::Cluster::GeneralCommissioning::CLUSTER_ID,
          command_id: Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE,
          fields: Bytes.empty)
        assert_standard_commissioning_complete!(response)
      ensure
        client.close
        scanner.close
      end
      cross_signed_icac
    end

    private def joint_handoff_parameters(request : CommandRequest) : {Bytes, UInt16}
      public_key = request.trusted_icac_public_key_b ||
                   raise Matter::ConfigurationError.new("JCM requires the authenticated Administrator ICAC public key")
      unless public_key.size == 65 && public_key[0] == UNCOMPRESSED_P256_POINT_TAG
        raise Matter::AuthenticationError.new("JCM Administrator ICAC public key is not uncompressed P-256")
      end
      endpoint = request.peer_admin_jfa_endpoint_id ||
                 raise Matter::ConfigurationError.new("JCM requires the peer Administrator endpoint")
      if endpoint == UInt16::MAX
        raise Matter::ConfigurationError.new("JCM peer Administrator endpoint is invalid")
      end
      {public_key, endpoint}
    end

    private def assert_standard_commissioning_complete!(response : Matter::InteractionModel::InvokeResponseMessage) : Nil
      response.invoke_responses.each do |entry|
        if status = entry.command_status
          raise Matter::CommissioningError.new("CommissioningComplete failed: IM status #{status.status.status}")
        end
        command = entry.command_data
        next unless command && command.command_path.command ==
                      Matter::Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE_RESPONSE
        fields = command.command_fields || raise Matter::ProtocolError.new("CommissioningComplete response omitted fields")
        result = Matter::Cluster::GeneralCommissioning::CommissioningCompleteResponse.from_slice(fields.to_slice)
        unless result.error_code.ok?
          raise Matter::CommissioningError.new("CommissioningComplete failed: #{result.error_code} #{result.debug_text}")
        end
        return
      end
      raise Matter::ProtocolError.new("CommissioningComplete response omitted command data")
    end

    private def execute_anchor_exchange(request : AnchorExchangeRequest) : Bytes
      own_fabric = @propagation_fabric || raise Matter::ConfigurationError.new("Anchor device has no provisioned fabric")
      unless request.fabric_id == own_fabric.fabric_id &&
             request.root_public_key == own_fabric.root_public_key
        raise Matter::AuthenticationError.new("Anchor exchange requested for a different fabric")
      end
      unless @anchor_role && has_anchor_cat?(own_fabric)
        raise Matter::AuthenticationError.new("Device is not the active Anchor")
      end
      identity = @controller_store.as(Matter::Controller::StateStore).load.fabric_for(
        own_fabric.fabric_id, own_fabric.root_public_key, own_fabric.node_id)
      # CASE must identify this reachable JFA device, not a controller process.
      unless identity.controller_node_id == own_fabric.node_id &&
             identity.controller_noc == own_fabric.operational_cert
        raise Matter::AuthenticationError.new("Anchor device CASE identity does not match its operational fabric")
      end
      identity.certificate_authority_key
      peer = Socket::IPAddress.new(request.peer_address, request.peer_port)
      client = leased_case_client(own_fabric.node_id, delegate_peer_initiated: true)
      begin
        session = Matter::Controller::Pairing::CasePairing.new.pair(client, peer,
          identity, peer_node_id: request.joining_node_id)
        # SDK JFA reads this Anchor's JFA attributes during Announce on the
        # very CASE session opened by this client. Route those peer requests to
        # the device while keeping Announce and ICAC exchange replies here.
        session.fabric_index = own_fabric.fabric_index
        message_handler.registry.establish_session(session, preserve_existing: true)
        im = Matter::Controller::ImClient.new(client, 45.seconds)
        endpoint = Matter::Controller::JointCommissioning.discover_administrator_endpoint(im, session, peer)
        unless endpoint == request.administrator_endpoint
          raise Matter::AuthenticationError.new("Joining Administrator endpoint changed before Anchor exchange")
        end
        response = im.invoke(session: session, peer: peer, endpoint_id: endpoint,
          cluster_id: Admin::CLUSTER_ID,
          command_id: Admin::CMD_ANNOUNCE_JOINT_FABRIC_ADMINISTRATOR,
          # The command target is the joining JFA; the payload identifies this Anchor's JFA.
          fields: Admin::AnnounceJointFabricAdministratorRequest.new(ANCHOR_JFA_ENDPOINT_ID).to_slice)
        Matter::Controller::JointCommissioning.assert_status_success(response)
        Matter::Controller::JointCommissioning.exchange_icac(im, session, peer,
          endpoint, identity.root_cert, identity.certificate_authority_key,
          identity.fabric_id, request.icac_public_key, request.icac_id)
      ensure
        client.close
      end
    end

    private def resolve_transfer_peer(scanner : Matter::Controller::Scanner,
                                      compressed_fabric_id : UInt64,
                                      node_id : UInt64,
                                      timeout : Time::Span = 10.seconds) : Socket::IPAddress
      deadline = Time.instant + timeout
      loop do
        if device = scanner.operational_devices.find { |entry| entry.fabric_id == compressed_fabric_id && entry.node_id == node_id }
          if address = device.addresses.find(&.family.inet?) || device.addresses.first?
            return Socket::IPAddress.new(
              Matter::Controller::OperationalPeerResolver.address_hint(address), device.port)
          end
        end
        break if Time.instant >= deadline
        sleep 100.milliseconds
      end
      if configured = configured_transfer_peer(node_id)
        return configured
      end
      raise Matter::TransportError.new("Could not discover transfer participant 0x#{node_id.to_s(16)}")
    end

    # A configured host is only a reachability hint. Every caller establishes
    # CASE for the selected fabric and expected Node ID before trusting it.
    private def configured_transfer_peer(node_id : UInt64) : Socket::IPAddress?
      address = configured_peer_hints[node_id]?
      return unless address
      ::Log.for("matter.example.joint_fabric_administrator").info do
        "Operational mDNS did not locate transfer participant 0x#{node_id.to_s(16)}; trying configured host"
      end
      address
    end

    # Route hints are only used after operational discovery fails. Every
    # caller still establishes CASE with the selected fabric and Node ID.
    private def configured_peer_hints : Hash(UInt64, Socket::IPAddress)
      hints = {} of UInt64 => Socket::IPAddress
      entries = ENV["MATTER_JFA_TRANSFER_PEERS"]?
      return hints unless entries
      port = ENV["MATTER_JFA_ANCHOR_OPERATIONAL_PORT"]?.try(&.to_i?) || DEFAULT_OPERATIONAL_PORT
      entries.split(',').each do |entry|
        parts = entry.split('=', 2)
        node_id = parts.first.to_u64?(16)
        host = parts[1]?
        if !node_id || !host || host.empty? || hints.has_key?(node_id)
          raise Matter::ConfigurationError.new("Invalid or duplicate configured Joint Fabric peer")
        end
        addresses = Socket::Addrinfo.resolve(host, port.to_s, type: Socket::Type::DGRAM)
        address = addresses.find(&.ip_address.family.inet6?) || addresses.first? ||
                  raise Matter::TransportError.new("Configured Joint Fabric peer hostname did not resolve")
        hints[node_id] = address.ip_address
      end
      hints
    end

    private def compliant_anchor_fabric?(fabric : Matter::Fabric) : Bool
      return false unless ENV["MATTER_JFA_PROVISIONED_ANCHOR"]? == "1"
      return false unless has_anchor_cat?(fabric)
      icac = fabric.intermediate_cert
      return false unless icac
      Matter::Crypto::MatterCertificate::Validation.verify_intermediate_profile(icac, fabric.fabric_id)
      true
    rescue Matter::Error
      false
    end

    private def has_anchor_cat?(fabric : Matter::Fabric) : Bool
      fabric.cats.any? { |cat| cat.identity_value == ANCHOR_CAT_ID && cat.version > 0_u16 }
    end

    private def verify_anchor_initiator(node_id : UInt64, fabric_index : UInt8,
                                        source : Socket::IPAddress, endpoint : UInt16) : Bool
      fabric = fabric_table.get_fabric(fabric_index)
      return false unless fabric
      trust = anchor_trust(fabric.vendor_id, ENV["MATTER_JFA_VID_TRUST_ROOT_PATH"]?,
        ENV["MATTER_JFA_TEST_DCL_GATEWAY_URL"]?, ENV["MATTER_JFA_DCL_GATEWAY_URL"]?)
      scanner = Matter::Controller::Scanner.new
      begin
        scanner.start
        scanner.query_operational
        compressed = IO::ByteFormat::BigEndian.decode(UInt64, fabric.compressed_fabric_id)
        peer = resolve_anchor_verification_peer(scanner, compressed, node_id, source)
      ensure
        scanner.close
      end
      # The fresh CASE verification must originate from this node's operational
      # listener. Some peers update the route for our Node ID from each CASE
      # handshake; an ephemeral verifier socket would divert their next JCM
      # command away from the JFA device.
      client = anchor_verification_client(fabric.node_id)
      begin
        Matter::Controller::JointCommissioning.verify_anchor_from_fabric(fabric, node_id, peer, trust,
          timeout: 15.seconds, client: client, administrator_endpoint: endpoint,
          on_verified_session: ->(session : Matter::Session::SecureContext) {
            # SDK Administrators can reuse this newly authenticated CASE
            # session for ICACCSRRequest immediately after Announce. The
            # listener must continue to receive it once this client closes.
            client.relinquish_session(session)
            session.fabric_index = fabric.fabric_index
            message_handler.registry.establish_session(session, preserve_existing: true)
          })
      ensure
        client.close
      end
      true
    rescue ex : Matter::Error | IO::Error
      ::Log.for("matter.example.joint_fabric_administrator").warn(exception: ex) { "Anchor VID verification failed" }
      false
    end

    # Only the opt-in interoperability fixture may use this local test mirror.
    # A VVS requires its DCL signer even when a static root is also configured
    # for the fixture's other, no-VVS fabrics.
    private def anchor_trust(vendor_id : UInt16, root_path : String?,
                             test_dcl_url : String?, dcl_url : String? = nil) : Matter::Controller::VidVerification::OperationalTrustAnchors
      if test_dcl_url && dcl_url
        raise Matter::ConfigurationError.new("Configure one Joint Fabric DCL gateway")
      end
      root_trust = if path = root_path
                     trusted_roots = path.split(',').map { |entry| File.read(entry.strip).to_slice.dup }
                     Matter::Controller::VidVerification::StaticOperationalTrustAnchors.new(
                       {vendor_id => trusted_roots})
                   end
      if url = test_dcl_url || dcl_url
        source = Matter::Controller::VidVerification::HttpDclSource.new(url)
        if test_dcl_url && !URI.parse(url).host.in?("127.0.0.1", "tests")
          raise Matter::ConfigurationError.new("Test DCL mirror must use loopback or the Compose tests service")
        end
        signer_trust = Matter::Controller::VidVerification::DclOperationalTrustAnchors.new(source)
        return root_trust ? Matter::Controller::VidVerification::CompositeOperationalTrustAnchors.new(
          root_trust, signer_trust) : signer_trust
      end
      root_trust || raise Matter::ConfigurationError.new("No operational Vendor ID trust source configured")
    end

    private def anchor_verification_client(node_id : UInt64,
                                           delegate_peer_initiated : Bool = false) : Matter::Controller::Client
      store = @controller_store || Matter::Controller::StateStore.new(persistence.backend)
      Matter::Controller::Client.new(
        transport: message_handler.transport,
        counter_lease: store.counter_lease(node_id),
        session_id_in_use: ->(id : UInt16) { message_handler.sessions.has_key?(id) },
        delegate_peer_initiated: delegate_peer_initiated
      )
    end

    private def leased_case_client(node_id : UInt64,
                                   delegate_peer_initiated : Bool = false) : Matter::Controller::Client
      anchor_verification_client(node_id, delegate_peer_initiated: delegate_peer_initiated)
    end

    # Announce arrived over an authenticated CASE session. Its UDP source is
    # therefore a route hint when operational DNS-SD misses a peer, including
    # SDK Administrators that listen on a dynamic port. The fresh outbound
    # CASE and VID verification above still authenticate the expected node.
    private def resolve_anchor_verification_peer(scanner : Matter::Controller::Scanner,
                                                 compressed_fabric_id : UInt64, node_id : UInt64,
                                                 source : Socket::IPAddress,
                                                 timeout : Time::Span = 2.seconds) : Socket::IPAddress
      resolve_transfer_peer(scanner, compressed_fabric_id, node_id, timeout)
    rescue Matter::TransportError
      listener_port = ENV["MATTER_JFA_ANCHOR_OPERATIONAL_PORT"]?.try(&.to_i?) || source.port
      raise Matter::TransportError.new("Anchor operational port is unavailable") unless listener_port > 0
      ::Log.for("matter.example.joint_fabric_administrator").info do
        "Operational mDNS did not locate authenticated Anchor; trying CASE source route"
      end
      Socket::IPAddress.new(
        Matter::Controller::OperationalPeerResolver.address_hint(source), listener_port)
    end

    private def accessing_fabric_identity(index : UInt8) : Matter::Commissioning::JointFabricAdministratorService::FabricIdentity?
      fabric = fabric_table.get_fabric(index)
      return unless fabric
      root = fabric.root_cert
      return unless root
      Matter::Commissioning::JointFabricAdministratorService::FabricIdentity.new(root, fabric.fabric_id)
    end

    private def provisioned_icac_key(fabric : Matter::Fabric, icac : Bytes) : Matter::Crypto::Key?
      public_key = Matter::Crypto::MatterCertificate.public_key_from_tlv(icac)
      state = if document = persistence.app_document(APP_KEY_DOCUMENT)
                IcacKeyState.from_document(document)
              else
                import_bootstrap_icac_key(fabric, icac, public_key)
              end
      return unless state && state.public_key == public_key
      key = Matter::Crypto::Key.new(Matter::Crypto::KeyType::EC, Matter::Crypto::CurveType::P256)
      key.private_bits = state.private_key
      return unless key.public_key == public_key
      persistence.write_app_document(APP_KEY_DOCUMENT, state.to_document) unless persistence.app_document(APP_KEY_DOCUMENT)
      key
    end

    private def import_bootstrap_icac_key(fabric : Matter::Fabric, icac : Bytes, public_key : Bytes) : IcacKeyState?
      path = ENV["MATTER_JFA_BOOTSTRAP_STATE_PATH"]?
      return unless path
      backend = Matter::Storage::YamlFile.new(path)
      begin
        source = Matter::Controller::StateStore.new(backend).load
        identity = source.fabrics.find do |candidate|
          candidate.fabric_id == fabric.fabric_id &&
            candidate.root_public_key == fabric.root_public_key &&
            candidate.intermediate_cert == icac
        end
        private_key = identity.try(&.intermediate_private_key)
        return unless private_key
        IcacKeyState.new(private_key, public_key)
      ensure
        backend.close if backend.open?
      end
    end

    private def open_joint_window(request : Admin::OpenJointCommissioningWindowRequest, fabric : Matter::Fabric) : Matter::InteractionModel::Status
      unless @anchor_role
        return Matter::InteractionModel::Status.unsupported_access
      end
      if persistence.app_document(APP_TRANSFER_WATCH_DOCUMENT) && !@participant_view_current
        ::Log.for("matter.example.joint_fabric_administrator").warn do
          "Joint Commissioning denied while the new Anchor Datastore view is stale"
        end
        return Matter::InteractionModel::Status.unsupported_access
      end
      unless ENV["MATTER_JFA_ALLOW_JCM"]? == "1"
        ::Log.for("matter.example.joint_fabric_administrator").info { "Joint Commissioning window denied by local consent policy" }
        return Matter::InteractionModel::Status.unsupported_access
      end
      open_joint_window_on_fabric(request, fabric)
    end

    private def open_bootstrap_joint_window(request : Admin::OpenJointCommissioningWindowRequest,
                                            fabric : Matter::Fabric) : Matter::InteractionModel::Status
      unless bootstrap_anchor_role? && bootstrap_joint_fabric_datastore.access_mode.active? &&
             ENV["MATTER_JFA_ALLOW_JCM"]? == "1"
        return Matter::InteractionModel::Status.unsupported_access
      end
      open_joint_window_on_fabric(request, fabric)
    end

    private def open_joint_window_on_fabric(request : Admin::OpenJointCommissioningWindowRequest,
                                            fabric : Matter::Fabric) : Matter::InteractionModel::Status
      normal = Matter::Cluster::AdministratorCommissioning::OpenCommissioningWindowRequest.new(
        request.commissioning_timeout,
        request.pake_passcode_verifier,
        request.discriminator,
        request.iterations,
        request.salt
      )
      administrator_commissioning.open_commissioning_window(normal, fabric.fabric_index, fabric.vendor_id, joint: true)
      Matter::InteractionModel::Status.success
    rescue ex : Matter::ClusterError
      ex.to_status
    rescue ArgumentError
      Matter::InteractionModel::Status.constraint_error
    end
  end
end
