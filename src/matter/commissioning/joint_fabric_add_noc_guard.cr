require "../cluster/joint_fabric_administrator"
require "../cluster/joint_fabric_datastore"
require "./joint_fabric_add_noc_policy"

module Matter
  module Commissioning
    # Binds a JCM PASE fail-safe to the administering Joint Fabric Datastore.
    # Credential validation reads the live GroupList, so CAT rotations cannot
    # leave a stale permitted version behind.
    class JointFabricAddNocGuard
      alias Admin = Cluster::JointFabricAdministrator
      alias Datastore = Cluster::JointFabricDatastore

      getter active_session_id : UInt64?
      getter active_datastore : Datastore?
      @installed = false

      def initialize(@credentials : CredentialService,
                     @administrators : Proc(Array(Admin)),
                     @datastore_at : Proc(UInt16, Datastore?))
      end

      def install! : Nil
        return if @installed
        @credentials.register_add_noc_guard(->(noc : Bytes, subject : UInt64, session_id : UInt64) {
          validate(noc, subject, session_id)
        })
        @installed = true
        bind_administrators
      end

      def bind_administrators : Nil
        @administrators.call.each do |administrator|
          administrator.jcm_add_noc_guard_ready = -> { ready_for?(administrator) }
        end
      end

      def ready_for?(administrator : Admin) : Bool
        return false unless @installed
        fabric_index = administrator.administrator_fabric_index
        return false unless fabric_index
        datastore = @datastore_at.call(administrator.endpoint_id.number)
        return false unless datastore && datastore.joint_fabric_index == fabric_index
        return false unless datastore.access_mode.active?
        !JointFabricAddNocPolicy.current_versions(datastore).nil?
      end

      def observe_failsafe_arm(session_id : UInt64?, window_fabric_index : UInt8?,
                               joint_window : Bool, case_session : Bool) : Nil
        reset
        return unless joint_window && session_id && window_fabric_index
        return if case_session
        @active_session_id = session_id
        candidates = @administrators.call.compact_map do |administrator|
          next unless administrator.administrator_fabric_index == window_fabric_index
          next unless ready_for?(administrator)
          @datastore_at.call(administrator.endpoint_id.number)
        end
        return unless candidates.size == 1
        @active_datastore = candidates.first
      end

      def reset : Nil
        @active_session_id = nil
        @active_datastore = nil
      end

      private def validate(noc : Bytes, case_admin_subject : UInt64, session_id : UInt64) : NocOutcome?
        return unless @active_session_id == session_id
        JointFabricAddNocPolicy.validate(noc, case_admin_subject, @active_datastore)
      end
    end
  end
end
