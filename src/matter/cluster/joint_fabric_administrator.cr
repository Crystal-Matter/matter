require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Joint Fabric Administrator cluster (0x0753).
    # Wire layout follows connectedhomeip v1.6.0.0's
    # joint-fabric-administrator-cluster.xml.
    class JointFabricAdministrator < Base
      cluster 0x0753, revision: 1

      MIN_ADMINISTRATOR_FABRIC_INDEX =   1_u8
      MAX_ADMINISTRATOR_FABRIC_INDEX = 254_u8
      PROVISIONAL_FABRIC_INDEX_KEY   = "provisional_administrator_fabric_index"

      private struct ProvisionalFabricIndex
        include Storage::Record

        getter previous : UInt8?

        def initialize(@previous : UInt8?)
        end
      end

      @provisional_fabric_index_active = false
      @previous_administrator_fabric_index : UInt8? = nil
      @provisional_commit_pending = false

      enum ICACCSRResponseStatusCodeEnum : UInt8
        OK                              = 0
        Busy                            = 1
        PAKEParameterError              = 2
        WindowNotOpen                   = 3
        VIDNotVerified                  = 4
        InvalidAdministratorFabricIndex = 5
      end

      enum ICACResponseStatusEnum : UInt8
        OK               = 0
        InvalidPublicKey = 1
        InvalidICAC      = 2
      end

      enum TransferAnchorResponseStatusEnum : UInt8
        OK                                = 0
        TransferAnchorStatusDatastoreBusy = 1
        TransferAnchorStatusNoUserConsent = 2
      end

      struct AddICACRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property icac_value : Bytes

        def initialize(
          @icac_value : Bytes,
        )
        end
      end

      struct OpenJointCommissioningWindowRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property commissioning_timeout : UInt16

        @[TLV::Field(tag: 1)]
        property pake_passcode_verifier : Bytes

        @[TLV::Field(tag: 2)]
        property discriminator : UInt16

        @[TLV::Field(tag: 3)]
        property iterations : UInt32

        @[TLV::Field(tag: 4)]
        property salt : Bytes

        def initialize(
          @commissioning_timeout : UInt16,
          @pake_passcode_verifier : Bytes,
          @discriminator : UInt16,
          @iterations : UInt32,
          @salt : Bytes,
        )
        end
      end

      struct AnnounceJointFabricAdministratorRequest
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property endpoint_id : UInt16

        def initialize(
          @endpoint_id : UInt16,
        )
        end
      end

      struct ICACCSRResponse
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property status_code : ICACCSRResponseStatusCodeEnum

        @[TLV::Field(tag: 1, optional: true)]
        property icaccsr : Bytes?

        def initialize(
          @status_code : ICACCSRResponseStatusCodeEnum,
          @icaccsr : Bytes? = nil,
        )
        end
      end

      struct ICACResponse
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property status_code : ICACResponseStatusEnum

        def initialize(
          @status_code : ICACResponseStatusEnum,
        )
        end
      end

      struct TransferAnchorResponse
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        property status_code : TransferAnchorResponseStatusEnum

        def initialize(
          @status_code : TransferAnchorResponseStatusEnum,
        )
        end
      end

      attribute 0x0000, :administrator_fabric_index, UInt8, nullable: true, read_access: :administer,
        min: MIN_ADMINISTRATOR_FABRIC_INDEX, max: MAX_ADMINISTRATOR_FABRIC_INDEX, persist: true

      # The attribute is read-only on the wire but set during local JFA
      # provisioning and AddICAC. Keep the local setter within fabric_idx's
      # normative 1..254 range as well.
      def administrator_fabric_index=(value : UInt8?) : Nil
        if value && (value < MIN_ADMINISTRATOR_FABRIC_INDEX || value > MAX_ADMINISTRATOR_FABRIC_INDEX)
          raise Matter::ConfigurationError.new("AdministratorFabricIndex must be in 1..254")
        end
        return if @administrator_fabric_index == value

        previous = @administrator_fabric_index
        @administrator_fabric_index = value
        increment_version_and_notify(ATTR_ADMINISTRATOR_FABRIC_INDEX)
        @on_administrator_fabric_index_changed.try &.call(previous, value)
      end

      # AddICAC changes this attribute under a fail-safe. Keep its rollback
      # value in the same cluster document, so an interrupted process cannot
      # restore the provisional index as if it were committed.
      def begin_provisional_administrator_fabric_index(value : UInt8) : Nil
        raise Matter::ConfigurationError.new("AdministratorFabricIndex is already provisional") if @provisional_fabric_index_active
        if value < MIN_ADMINISTRATOR_FABRIC_INDEX || value > MAX_ADMINISTRATOR_FABRIC_INDEX
          raise Matter::ConfigurationError.new("AdministratorFabricIndex must be in 1..254")
        end

        @previous_administrator_fabric_index = @administrator_fabric_index
        @provisional_fabric_index_active = true
        self.administrator_fabric_index = value
        increment_version
      end

      def commit_provisional_administrator_fabric_index : Nil
        return unless @provisional_fabric_index_active

        @provisional_fabric_index_active = false
        @previous_administrator_fabric_index = nil
        increment_version
      end

      # A host that persists the ICAC and this cluster in one backend
      # transaction must save the post-commit cluster document before the
      # service drops its in-memory fail-safe state. A failed callback leaves
      # the ordinary provisional snapshot in force for retries or rollback.
      def with_pending_provisional_commit(& : -> Nil) : Nil
        raise Matter::ConfigurationError.new("AdministratorFabricIndex is not provisional") unless @provisional_fabric_index_active
        raise Matter::ConfigurationError.new("AdministratorFabricIndex commit is already pending") if @provisional_commit_pending
        @provisional_commit_pending = true
        begin
          yield
        ensure
          @provisional_commit_pending = false
        end
      end

      def rollback_provisional_administrator_fabric_index : Nil
        return unless @provisional_fabric_index_active

        previous = @previous_administrator_fabric_index
        @provisional_fabric_index_active = false
        @previous_administrator_fabric_index = nil
        self.administrator_fabric_index = previous
        increment_version
      end

      private def extend_persisted_state(document : Storage::Document) : Nil
        if @provisional_fabric_index_active && !@provisional_commit_pending
          document[PROVISIONAL_FABRIC_INDEX_KEY] = ProvisionalFabricIndex.new(@previous_administrator_fabric_index).to_document
        end
      end

      private def restore_persisted_extension(document : Storage::Document) : Nil
        if value = document[PROVISIONAL_FABRIC_INDEX_KEY]?
          state = ProvisionalFabricIndex.from_document(value.as?(Storage::Document) ||
                                                       raise StorageError.new("Invalid provisional AdministratorFabricIndex"))
          previous = state.previous
          if previous && (previous < MIN_ADMINISTRATOR_FABRIC_INDEX || previous > MAX_ADMINISTRATOR_FABRIC_INDEX)
            raise StorageError.new("Invalid previous AdministratorFabricIndex")
          end
          @previous_administrator_fabric_index = previous
          @provisional_fabric_index_active = true
        end
      end

      private def after_restore_state : Nil
        rollback_provisional_administrator_fabric_index
      end

      command 0x00, :icaccsr_request, response_id: 0x01, access: :administer
      command 0x02, :add_icac, request: AddICACRequest, response_id: 0x03, access: :administer
      command 0x04, :open_joint_commissioning_window, request: OpenJointCommissioningWindowRequest, access: :administer
      command 0x05, :transfer_anchor_request, response_id: 0x06, access: :administer
      command 0x07, :transfer_anchor_complete, access: :administer
      command 0x08, :announce_joint_fabric_administrator, request: AnnounceJointFabricAdministratorRequest, access: :administer

      # The administrator's key material and consent workflow live in the
      # commissioning service. Keeping the wire contract here avoids a cycle
      # between the cluster and that service.
      module Service
        abstract def icaccsr_request(cluster : JointFabricAdministrator) : ICACCSRResponse | InteractionModel::Status
        abstract def add_icac(cluster : JointFabricAdministrator, request : AddICACRequest) : ICACResponse | InteractionModel::Status
        abstract def open_joint_commissioning_window(cluster : JointFabricAdministrator, request : OpenJointCommissioningWindowRequest) : InteractionModel::Status
        abstract def transfer_anchor_request(cluster : JointFabricAdministrator) : TransferAnchorResponse | InteractionModel::Status
        abstract def transfer_anchor_complete(cluster : JointFabricAdministrator) : InteractionModel::Status
        abstract def announce_joint_fabric_administrator(cluster : JointFabricAdministrator, request : AnnounceJointFabricAdministratorRequest) : InteractionModel::Status
      end

      property service : Service?

      def icaccsr_request : ICACCSRResponse | InteractionModel::Status
        service = @service
        return InteractionModel::Status.failure unless service
        service.icaccsr_request(self)
      end

      def add_icac(request : AddICACRequest) : ICACResponse | InteractionModel::Status
        service = @service
        return InteractionModel::Status.failure unless service
        service.add_icac(self, request)
      end

      def open_joint_commissioning_window(request : OpenJointCommissioningWindowRequest) : InteractionModel::Status
        service = @service
        return InteractionModel::Status.failure unless service
        service.open_joint_commissioning_window(self, request)
      end

      def transfer_anchor_request : TransferAnchorResponse | InteractionModel::Status
        service = @service
        return InteractionModel::Status.failure unless service
        service.transfer_anchor_request(self)
      end

      def transfer_anchor_complete : InteractionModel::Status
        service = @service
        return InteractionModel::Status.failure unless service
        service.transfer_anchor_complete(self)
      end

      def announce_joint_fabric_administrator(request : AnnounceJointFabricAdministratorRequest) : InteractionModel::Status
        service = @service
        return InteractionModel::Status.failure unless service
        service.announce_joint_fabric_administrator(self, request)
      end
    end
  end
end
