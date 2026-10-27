require "../datatype/node_id"
require "../storage/record"

module Matter
  module Controller
    struct NodeInfo
      include Storage::Record

      # Default Matter operational UDP port.
      DEFAULT_PORT = 5540

      getter node_id : UInt64
      getter address : String?
      getter port : Int32

      def initialize(@node_id : UInt64, @address : String? = nil, @port : Int32 = DEFAULT_PORT)
      end
    end

    # AddNOC succeeded but a separate JFA is responsible for sending
    # CommissioningComplete. This is deliberately separate from commissioned
    # nodes so a restart cannot mistake a provisional fabric for completion.
    struct PendingCommissioningHandoff
      include Storage::Record

      getter fabric_id : UInt64
      getter root_public_key : Bytes
      getter controller_node_id : UInt64
      getter node_id : UInt64
      getter address : String
      getter port : Int32
      getter expires_at_unix : Int64
      getter nonce : String

      def initialize(@fabric_id : UInt64, @root_public_key : Bytes,
                     @controller_node_id : UInt64, @node_id : UInt64,
                     @address : String, @port : Int32, @expires_at_unix : Int64,
                     @nonce : String)
        raise Matter::ConfigurationError.new("Commissioning handoff nonce is required") if @nonce.empty?
      end
    end

    # A Datastore operation can outlive the commissioning exchange. Persist
    # this before AddPendingNode so a restart can reconcile its network effect.
    struct PendingDatastoreNode
      include Storage::Record

      enum Stage : UInt8
        Pending
        Registered
        Completing
        Completed
      end

      getter fabric_id : UInt64
      getter root_public_key : Bytes
      getter controller_node_id : UInt64
      getter node_id : UInt64
      getter friendly_name : String
      property expires_at_unix : Int64
      getter peer_address : String?
      getter peer_port : Int32
      property stage : Stage

      def initialize(@fabric_id, @root_public_key, @controller_node_id, @node_id,
                     @friendly_name, @expires_at_unix : Int64 = 0_i64,
                     @peer_address : String? = nil, @peer_port : Int32 = NodeInfo::DEFAULT_PORT,
                     @stage : Stage = Stage::Pending)
      end
    end

    struct FabricInfo
      include Storage::Record

      # Default (test) vendor id used when creating a fabric.
      DEFAULT_ADMIN_VENDOR_ID    = 0xFFF1_u16
      COMPRESSED_FABRIC_ID_BYTES =          8
      COMPRESSED_FABRIC_INFO     = "CompressedFabric".to_slice

      getter fabric_id : UInt64
      getter controller_node_id : UInt64

      # Raw epoch key (IPK value) provided during AddNOC (16 bytes).
      getter ipk_value : Bytes

      # Optional KeySet-0 epochs, oldest first. Legacy stores use ipk_value.
      @ipk_epoch_keys : Array(Bytes) = [] of Bytes

      # TLV root certificate provided via AddTrustedRootCertificate.
      getter root_cert : Bytes

      # Root public key extracted from root cert (65 bytes, uncompressed point).
      getter root_public_key : Bytes

      # Controller operational identity (NOC + private key).
      getter controller_noc : Bytes
      getter controller_private_key : Bytes

      # Intermediate CA certificate in the controller's operational chain.
      # Also supplied with a device NOC issued by the same authority.
      getter intermediate_cert : Bytes?

      # Signing key for an installed ICAC, when this controller owns it.
      getter intermediate_private_key : Bytes?

      # Private key of the root certificate, which is what issues a node
      # certificate to each device this controller commissions. Nil for a
      # fabric created before the controller kept it, which can still connect
      # to the devices it already commissioned but cannot commission new ones.
      getter root_private_key : Bytes?

      getter admin_vendor_id : UInt16

      def initialize(
        @fabric_id : UInt64,
        @controller_node_id : UInt64,
        @ipk_value : Bytes,
        @root_cert : Bytes,
        @root_public_key : Bytes,
        @controller_noc : Bytes,
        @controller_private_key : Bytes,
        @root_private_key : Bytes? = nil,
        @admin_vendor_id : UInt16 = DEFAULT_ADMIN_VENDOR_ID,
        @intermediate_cert : Bytes? = nil,
        @intermediate_private_key : Bytes? = nil,
        ipk_epoch_keys : Array(Bytes)? = nil,
      )
        self.ipk_epoch_keys = ipk_epoch_keys if ipk_epoch_keys
      end

      def ipk_epoch_keys : Array(Bytes)
        @ipk_epoch_keys.empty? ? [@ipk_value] : @ipk_epoch_keys
      end

      def ipk_epoch_keys=(keys : Array(Bytes)) : Nil
        raise Matter::ConfigurationError.new("IPK requires one to three epoch keys") unless (1..3).includes?(keys.size)
        raise Matter::ConfigurationError.new("IPK epoch key must be 16 bytes") unless keys.all?(&.size.==(Fabric::IPK_SIZE))
        @ipk_epoch_keys = keys.map(&.dup)
        @ipk_value = @ipk_epoch_keys.first.dup
      end

      def case_ipk_value : Bytes
        keys = ipk_epoch_keys
        keys.size > 1 ? keys[keys.size - 2] : keys.first
      end

      # The key pair this fabric issues certificates with
      def certificate_authority_key : Crypto::Key
        private_key = @root_private_key
        if private_key.nil?
          raise Matter::ConfigurationError.new(
            "Fabric 0x#{@fabric_id.to_s(16)} has no certificate authority key; re-pair to commission new devices"
          )
        end

        # Set the public key from the fabric rather than deriving it: the
        # fabric already carries it, and a derivation is a round trip through
        # OpenSSL that a restricted build can refuse.
        key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
        key.public_bits = @root_public_key
        key.private_bits = private_key
        key
      end

      def intermediate_authority_key : Crypto::Key
        cert = @intermediate_cert || raise Matter::ConfigurationError.new("Fabric has no intermediate certificate")
        private_key = @intermediate_private_key || raise Matter::ConfigurationError.new("Fabric has no intermediate CA key")
        key = Crypto::Key.new(Crypto::KeyType::EC, Crypto::CurveType::P256)
        key.public_bits = Crypto::MatterCertificate.public_key_from_tlv(cert)
        key.private_bits = private_key
        key
      end

      # The mDNS operational instance name uses the compressed fabric ID,
      # derived from the root public key and the raw Fabric ID.
      def compressed_fabric_id : UInt64
        salt = Bytes.new(COMPRESSED_FABRIC_ID_BYTES)
        IO::ByteFormat::BigEndian.encode(@fabric_id, salt)
        bytes = Crypto.create_hkdf_key(@root_public_key[1..-1], salt, COMPRESSED_FABRIC_INFO, COMPRESSED_FABRIC_ID_BYTES)
        IO::ByteFormat::BigEndian.decode(UInt64, bytes)
      end
    end

    # Current operational group key for a group on one logical fabric. Store
    # only the derived key, never the provisioned epoch input key.
    struct GroupKeyInfo
      include Storage::Record

      getter fabric_id : UInt64
      getter root_public_key : Bytes
      getter group_id : UInt16
      getter operational_key : Bytes

      def initialize(@fabric_id : UInt64, @root_public_key : Bytes,
                     @group_id : UInt16, @operational_key : Bytes)
      end
    end

    struct State
      include Storage::Record

      # A loaded State carries an immutable snapshot for stale-write checks.
      @[Storage::Field(ignore: true)]
      property storage_snapshot : Storage::Document? = nil

      @[Storage::Field(ignore: true)]
      property? storage_loaded : Bool = false

      property fabric : FabricInfo?
      property nodes : Hash(UInt64, NodeInfo)

      # The selected fabric remains in the original fields so existing stores
      # and callers continue to work. Other fabrics keep independent peer maps.
      property other_fabrics : Hash(String, FabricInfo) = {} of String => FabricInfo
      property other_nodes : Hash(String, Hash(UInt64, NodeInfo)) = {} of String => Hash(UInt64, NodeInfo)
      property pending_handoffs : Array(PendingCommissioningHandoff) = [] of PendingCommissioningHandoff
      property pending_datastore_nodes : Array(PendingDatastoreNode) = [] of PendingDatastoreNode
      property group_keys : Array(GroupKeyInfo) = [] of GroupKeyInfo

      # Commissioner node id used for unsecured message source_node_id and as the
      # controller node id when creating a new fabric.
      property commissioner_node_id : UInt64 = DataType::NodeId::UNSPECIFIED

      # Monotonic counter for unsecured (session_id=0) messages. This must not go
      # backwards across process restarts or peers may treat requests as stale.
      property unsecured_message_counter : UInt32 = 0_u32

      UNSECURED_COUNTER_HALF_RANGE = 1_u32 << 31

      # Accept a counter from a client that may have started from an older
      # snapshot. Serial arithmetic also handles a legitimate UInt32 wrap.
      def advance_unsecured_message_counter(candidate : UInt32) : Nil
        distance = candidate &- @unsecured_message_counter
        if distance > 0_u32 && distance < UNSECURED_COUNTER_HALF_RANGE
          @unsecured_message_counter = candidate
        end
      end

      def initialize(
        @fabric : FabricInfo? = nil,
        @nodes : Hash(UInt64, NodeInfo) = {} of UInt64 => NodeInfo,
        @commissioner_node_id : UInt64 = DataType::NodeId::UNSPECIFIED,
        @unsecured_message_counter : UInt32 = 0_u32,
        @other_fabrics : Hash(String, FabricInfo) = {} of String => FabricInfo,
        @other_nodes : Hash(String, Hash(UInt64, NodeInfo)) = {} of String => Hash(UInt64, NodeInfo),
        @pending_handoffs : Array(PendingCommissioningHandoff) = [] of PendingCommissioningHandoff,
        @pending_datastore_nodes : Array(PendingDatastoreNode) = [] of PendingDatastoreNode,
        @group_keys : Array(GroupKeyInfo) = [] of GroupKeyInfo,
      )
      end

      def fabrics : Array(FabricInfo)
        result = [] of FabricInfo
        if active = @fabric
          result << active
        end
        result.concat(@other_fabrics.values)
        result
      end

      def fabric_for(fabric_id : UInt64, root_public_key : Bytes? = nil, controller_node_id : UInt64? = nil) : FabricInfo
        matches = fabrics.select do |candidate|
          candidate.fabric_id == fabric_id &&
            (root_public_key.nil? || candidate.root_public_key == root_public_key) &&
            (controller_node_id.nil? || candidate.controller_node_id == controller_node_id)
        end
        if matches.empty?
          raise Matter::ConfigurationError.new("No controller identity for fabric 0x#{fabric_id.to_s(16)}")
        end
        if matches.size > 1
          raise Matter::ConfigurationError.new("Fabric ID 0x#{fabric_id.to_s(16)} is ambiguous; provide its root public key and controller Node ID")
        end
        matches.first
      end

      def install_fabric(value : FabricInfo) : Nil
        key = fabric_key(value)
        if @fabric && fabric_key(@fabric.as(FabricInfo)) == key || @other_fabrics.has_key?(key)
          raise Matter::ConfigurationError.new("Controller identity for fabric 0x#{value.fabric_id.to_s(16)} is already installed")
        end
        if @fabric.nil?
          @fabric = value
          @commissioner_node_id = value.controller_node_id
        else
          @other_fabrics[key] = value
          @other_nodes[key] = {} of UInt64 => NodeInfo
        end
      end

      # Replace credentials for an installed identity without discarding its
      # peer records or changing the selected fabric.
      def replace_fabric(value : FabricInfo) : Nil
        key = fabric_key(value)
        if active = @fabric
          if fabric_key(active) == key
            @fabric = value
            return
          end
        end
        if @other_fabrics.has_key?(key)
          @other_fabrics[key] = value
          return
        end
        raise Matter::ConfigurationError.new("Controller identity for fabric 0x#{value.fabric_id.to_s(16)} is not installed")
      end

      def select_fabric(fabric_id : UInt64, root_public_key : Bytes? = nil, controller_node_id : UInt64? = nil) : FabricInfo
        selected = fabric_for(fabric_id, root_public_key, controller_node_id)
        return selected if @fabric && fabric_key(@fabric.as(FabricInfo)) == fabric_key(selected)

        selected_key = fabric_key(selected)
        old = @fabric
        if old
          old_key = fabric_key(old)
          @other_fabrics[old_key] = old
          @other_nodes[old_key] = @nodes
        end
        @fabric = @other_fabrics.delete(selected_key)
        @nodes = @other_nodes.delete(selected_key) || {} of UInt64 => NodeInfo
        @commissioner_node_id = selected.controller_node_id
        selected
      end

      # Remove one controller identity and its remembered peers. If it was the
      # active identity, select another installed identity when available.
      def remove_fabric(fabric_id : UInt64, root_public_key : Bytes? = nil, controller_node_id : UInt64? = nil) : FabricInfo
        selected = fabric_for(fabric_id, root_public_key, controller_node_id)
        key = fabric_key(selected)
        @pending_handoffs.reject! do |entry|
          entry.fabric_id == selected.fabric_id && entry.root_public_key == selected.root_public_key &&
            entry.controller_node_id == selected.controller_node_id
        end
        if @fabric && fabric_key(@fabric.as(FabricInfo)) == key
          @fabric = nil
          @nodes = {} of UInt64 => NodeInfo
          if next_fabric = @other_fabrics.values.first?
            next_key = fabric_key(next_fabric)
            @fabric = @other_fabrics.delete(next_key)
            @nodes = @other_nodes.delete(next_key) || {} of UInt64 => NodeInfo
            @commissioner_node_id = next_fabric.controller_node_id
          end
        else
          @other_fabrics.delete(key)
          @other_nodes.delete(key)
        end
        unless fabrics.any? { |fabric| fabric.fabric_id == selected.fabric_id && fabric.root_public_key == selected.root_public_key }
          @group_keys.reject! { |entry| entry.fabric_id == selected.fabric_id && entry.root_public_key == selected.root_public_key }
        end
        selected
      end

      def nodes_for(fabric_id : UInt64, root_public_key : Bytes? = nil, controller_node_id : UInt64? = nil) : Hash(UInt64, NodeInfo)
        selected = fabric_for(fabric_id, root_public_key, controller_node_id)
        return @nodes if @fabric && fabric_key(@fabric.as(FabricInfo)) == fabric_key(selected)
        @other_nodes[fabric_key(selected)] ||= {} of UInt64 => NodeInfo
      end

      def record_node(fabric_id : UInt64, node : NodeInfo, root_public_key : Bytes? = nil, controller_node_id : UInt64? = nil) : Nil
        nodes_for(fabric_id, root_public_key, controller_node_id)[node.node_id] = node
      end

      def add_pending_handoff(handoff : PendingCommissioningHandoff) : Nil
        fabric_for(handoff.fabric_id, handoff.root_public_key, handoff.controller_node_id)
        if @pending_handoffs.any? do |entry|
             entry.fabric_id == handoff.fabric_id && entry.root_public_key == handoff.root_public_key &&
             entry.controller_node_id == handoff.controller_node_id && entry.node_id == handoff.node_id
           end
          raise Matter::ConfigurationError.new("Commissioning handoff is already pending")
        end
        @pending_handoffs << handoff
      end

      # Call only after the JFA's authenticated finalizer reported success.
      def complete_pending_handoff(fabric_id : UInt64, root_public_key : Bytes,
                                   controller_node_id : UInt64, node_id : UInt64,
                                   nonce : String) : NodeInfo
        consume_pending_handoff(fabric_id, root_public_key, controller_node_id,
          node_id, nonce, require_fresh: true)
      end

      # The caller must first verify a separately persisted acknowledgement
      # from the JFA. Once CommissioningComplete succeeded, expiration of the
      # old fail-safe cannot invalidate recovery of controller-local state.
      def recover_acknowledged_handoff(fabric_id : UInt64, root_public_key : Bytes,
                                       controller_node_id : UInt64, node_id : UInt64,
                                       nonce : String) : NodeInfo
        consume_pending_handoff(fabric_id, root_public_key, controller_node_id,
          node_id, nonce, require_fresh: false)
      end

      # Called only after an authenticated device read proves that the
      # provisional fabric rolled back. Match the complete saved handoff so a
      # concurrent replacement cannot be discarded by an older recovery.
      def abandon_pending_handoff(expected : PendingCommissioningHandoff) : Nil
        index = @pending_handoffs.index { |entry| entry.to_document == expected.to_document }
        raise Matter::CommissioningError.new("Deferred handoff changed during recovery") unless index
        @pending_handoffs.delete_at(index)
      end

      private def consume_pending_handoff(fabric_id : UInt64, root_public_key : Bytes,
                                          controller_node_id : UInt64, node_id : UInt64,
                                          nonce : String, require_fresh : Bool) : NodeInfo
        index = @pending_handoffs.index do |entry|
          entry.fabric_id == fabric_id && entry.root_public_key == root_public_key &&
            entry.controller_node_id == controller_node_id && entry.node_id == node_id
        end
        raise Matter::ConfigurationError.new("No pending commissioning handoff") unless index
        handoff = @pending_handoffs[index]
        if handoff.nonce != nonce || (require_fresh && Time.utc.to_unix > handoff.expires_at_unix)
          raise Matter::AuthenticationError.new("Commissioning handoff result nonce or deadline mismatch")
        end
        @pending_handoffs.delete_at(index)
        node = NodeInfo.new(handoff.node_id, handoff.address, handoff.port)
        record_node(fabric_id, node, root_public_key, controller_node_id)
        node
      end

      private def fabric_key(value : FabricInfo) : String
        "#{value.fabric_id.to_s(16)}:#{value.root_public_key.hexstring}:#{value.controller_node_id.to_s(16)}"
      end
    end
  end
end
