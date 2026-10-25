require "../spec_helper"

private alias Def = Matter::Cluster::DoorLock

private def lock_request(pin : String? = nil) : Def::LockDoorRequest
  Def::LockDoorRequest.new(pin.try(&.to_slice))
end

private def unlock_with_timeout_request(timeout : UInt16, pin : String? = nil) : Def::UnlockWithTimeoutRequest
  Def::UnlockWithTimeoutRequest.new(timeout, pin.try(&.to_slice))
end

describe Matter::Cluster::DoorLock do
  describe "initialization" do
    it "creates with expected defaults" do
      cluster = build(Matter::Cluster::DoorLock)

      cluster.cluster_id.id.should eq(0x0101_u32)
      cluster.name.should eq("DoorLock")
      cluster.lock_state.should eq(Def::LockState::Locked)
      cluster.lock_type.should eq(Def::LockType::Deadbolt)
      cluster.actuator_enabled?.should be_true
      cluster.data_version.should eq(0_u32)
    end

    it "includes unbolt command only when unbolting feature is enabled" do
      cluster = build(Matter::Cluster::DoorLock,
        feature_map: Matter::Cluster::DoorLock::Feature::None
      )

      cluster.commands.map(&.id.id).includes?(Matter::Cluster::DoorLock::CMD_UNBOLT_DOOR).should be_false
    end

    it "uses Matter 1.6 SoundVolume wire values" do
      Def::SoundVolume::High.value.should eq(2_u8)
      Def::SoundVolume::Medium.value.should eq(3_u8)
      read(build(Def), Def::ATTR_SOUND_VOLUME).should eq(3_u8)
    end

    it "sets reserved bits and supports both mandatory operating modes" do
      cluster = build(Def)
      modes = cluster.supported_operating_modes

      (modes & 0xFFE0_u16).should eq(0xFFE0_u16)
      (modes & 0x0001_u16).should eq(0_u16)
      (modes & 0x0008_u16).should eq(0_u16)
      modes.should eq(0xFFF6_u16)
      read(cluster, Def::ATTR_SUPPORTED_OPERATING_MODES).should eq(modes)
    end

    it "rejects invalid operating-mode masks at construction" do
      expect_raises(ArgumentError) { build(Def, supported_operating_modes: 0_u16) }
      expect_raises(ArgumentError) { build(Def, supported_operating_modes: 0xFFE1_u16) }
      expect_raises(ArgumentError) { build(Def, supported_operating_modes: 0xFFE8_u16) }
      expect_raises(ArgumentError) do
        build(Def, supported_operating_modes: 0xFFE2_u16, operating_mode: Def::OperatingMode::Vacation)
      end
    end

    it "requires User when a credential feature is advertised" do
      [Def::Feature::PinCredential, Def::Feature::RfidCredential,
       Def::Feature::FingerCredentials, Def::Feature::FaceCredentials,
       Def::Feature::AliroProvisioning].each do |feature|
        expect_raises(ArgumentError) { build(Def, feature_map: feature) }
      end
    end
  end

  describe "operating mode" do
    it "rejects a write to an unsupported operating mode without changing it" do
      cluster = build(Def, supported_operating_modes: 0xFFE2_u16)
      before_version = cluster.data_version

      expect_status(write(cluster, Def::ATTR_OPERATING_MODE, Def::OperatingMode::Vacation.value),
        Matter::InteractionModel::StatusCode::ConstraintError)
      cluster.operating_mode.should eq(Def::OperatingMode::Normal)
      cluster.data_version.should eq(before_version)

      expect_success(write(cluster, Def::ATTR_OPERATING_MODE, Def::OperatingMode::Privacy.value))
      cluster.operating_mode.should eq(Def::OperatingMode::Privacy)
    end

    it "allows Privacy mode only while locked" do
      expect_raises(ArgumentError) do
        build(Def, lock_state: Def::LockState::Unlocked,
          supported_operating_modes: 0xFFE2_u16,
          operating_mode: Def::OperatingMode::Privacy)
      end

      cluster = build(Def, lock_state: Def::LockState::Unlocked,
        supported_operating_modes: 0xFFE2_u16)
      before_version = cluster.data_version
      expect_status(write(cluster, Def::ATTR_OPERATING_MODE, Def::OperatingMode::Privacy.value),
        Matter::InteractionModel::StatusCode::ConstraintError)
      cluster.operating_mode.should eq(Def::OperatingMode::Normal)
      cluster.data_version.should eq(before_version)
    end

    it "returns to Normal mode after manual unlocking from Privacy" do
      cluster = build(Def, supported_operating_modes: 0xFFE2_u16,
        operating_mode: Def::OperatingMode::Privacy)

      expect_status(cluster.unlock,
        Matter::InteractionModel::StatusCode::Failure)
      cluster.lock_state.should eq(Def::LockState::Locked)

      expect_success(cluster.unlock(source: Def::OperationSource::Manual))
      cluster.lock_state.should eq(Def::LockState::Unlocked)
      cluster.operating_mode.should eq(Def::OperatingMode::Normal)
    end

    it "publishes Normal mode before manual unlocking changes the lock state" do
      cluster = build(Def, supported_operating_modes: 0xFFE2_u16,
        operating_mode: Def::OperatingMode::Privacy)
      published = [] of Tuple(UInt32, Def::LockState?, Def::OperatingMode)
      cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, attribute : UInt32) {
        published << {attribute, cluster.lock_state, cluster.operating_mode}
        nil
      }

      expect_success(cluster.unlock(source: Def::OperationSource::Manual))

      published.should eq([
        {Def::ATTR_OPERATING_MODE, Def::LockState::Locked, Def::OperatingMode::Normal},
        {Def::ATTR_LOCK_STATE, Def::LockState::Unlocked, Def::OperatingMode::Normal},
      ])
    end
  end

  describe "lock commands" do
    it "invokes unlock and lock and updates lock state" do
      cluster = build(Matter::Cluster::DoorLock)

      unlock_result = invoke(cluster, Matter::Cluster::DoorLock::CMD_UNLOCK_DOOR, lock_request)
      unlock_result.should be_a(Matter::InteractionModel::Status)
      unlock_result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.lock_state.should eq(Def::LockState::Unlocked)

      lock_result = invoke(cluster, Matter::Cluster::DoorLock::CMD_LOCK_DOOR, lock_request)
      lock_result.should be_a(Matter::InteractionModel::Status)
      lock_result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.lock_state.should eq(Def::LockState::Locked)
    end

    it "notifies lockState updates for subscriptions" do
      cluster = build(Matter::Cluster::DoorLock)

      notified_attrs = [] of UInt32
      cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, attr : UInt32) {
        notified_attrs << attr
      }

      invoke(cluster, Matter::Cluster::DoorLock::CMD_UNLOCK_DOOR, lock_request)

      notified_attrs.should contain(Matter::Cluster::DoorLock::ATTR_LOCK_STATE)
    end

    it "auto-relocks after unlockWithTimeout" do
      cluster = build(Matter::Cluster::DoorLock)

      result = invoke(cluster,
        Matter::Cluster::DoorLock::CMD_UNLOCK_WITH_TIMEOUT,
        unlock_with_timeout_request(1_u16)
      )
      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).success?.should be_true

      cluster.lock_state.should eq(Def::LockState::Unlocked)
      sleep 1.2.seconds
      cluster.lock_state.should eq(Def::LockState::Locked)
    end

    it "returns UnsupportedCommand for unbolt when feature disabled" do
      cluster = build(Matter::Cluster::DoorLock,
        feature_map: Matter::Cluster::DoorLock::Feature::None
      )

      result = invoke(cluster, Matter::Cluster::DoorLock::CMD_UNBOLT_DOOR, lock_request)
      result.should be_a(Matter::InteractionModel::Status)

      status = result.as(Matter::InteractionModel::Status)
      status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedCommand)
    end

    it "unbolts without pulling the latch and reports an Unlock operation" do
      cluster = build(Def, require_pin_for_remote_operation: true, default_pin_code: "2468")
      emitted = [] of TLV::Any
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
        emitted << data if event == Def::EVENT_LOCK_OPERATION
        nil
      end

      request = Def::UnboltDoorRequest.new(pin_code: "2468".to_slice)
      expect_success(invoke(cluster, Def::CMD_UNBOLT_DOOR, request, fabric_index: 1_u8))

      cluster.lock_state.should eq(Def::LockState::Unlocked)
      emitted.size.should eq(1)
      Def::Events::LockOperation.from_tlv(emitted.first).lock_operation_type.should eq(Def::LockOperationType::Unlock)
    end
  end

  describe "door position sensor updates" do
    it "updates counters and notifies changed attributes" do
      cluster = build(Matter::Cluster::DoorLock)

      notified_attrs = [] of UInt32
      cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, attr : UInt32) {
        notified_attrs << attr
      }

      cluster.update_door_state(Def::DoorState::DoorOpen)

      cluster.door_open_events.should eq(1_u32)
      cluster.door_closed_events.should eq(0_u32)
      notified_attrs.should contain(Matter::Cluster::DoorLock::ATTR_DOOR_STATE)
      notified_attrs.should contain(Matter::Cluster::DoorLock::ATTR_DOOR_OPEN_EVENTS)
    end

    it "increments closed counter when transitioning to closed" do
      cluster = build(Matter::Cluster::DoorLock)

      cluster.update_door_state(Def::DoorState::DoorOpen)
      cluster.update_door_state(Def::DoorState::DoorClosed)

      cluster.door_open_events.should eq(1_u32)
      cluster.door_closed_events.should eq(1_u32)
    end
  end

  describe "pin authorization" do
    it "requires pin when RequirePinForRemoteOperation is enabled" do
      cluster = build(Matter::Cluster::DoorLock,
        require_pin_for_remote_operation: true
      )

      result = invoke(cluster, Matter::Cluster::DoorLock::CMD_UNLOCK_DOOR, lock_request)
      result.should be_a(Matter::InteractionModel::Status)

      status = result.as(Matter::InteractionModel::Status)
      status.status.should eq(Matter::InteractionModel::StatusCode::Failure)
      status.cluster_status.should eq(Def::StatusCode::InvalidField.value)
    end

    it "accepts default pin for remote operations" do
      cluster = build(Matter::Cluster::DoorLock,
        require_pin_for_remote_operation: true,
        default_pin_code: "2468"
      )

      result = invoke(cluster, Matter::Cluster::DoorLock::CMD_UNLOCK_DOOR, lock_request("2468"))
      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).success?.should be_true
    end

    it "enters temporary lockout after too many wrong pin attempts" do
      cluster = build(Matter::Cluster::DoorLock,
        require_pin_for_remote_operation: true,
        default_pin_code: "2468",
        wrong_code_entry_limit: 1_u8,
        user_code_temporary_disable_time: 1_u8
      )

      wrong_result = invoke(cluster, Matter::Cluster::DoorLock::CMD_UNLOCK_DOOR, lock_request("0000"))
      wrong_status = wrong_result.as(Matter::InteractionModel::Status)
      wrong_status.status.should eq(Matter::InteractionModel::StatusCode::Failure)
      wrong_status.cluster_status.should eq(Def::StatusCode::InvalidField.value)

      locked_out_result = invoke(cluster, Matter::Cluster::DoorLock::CMD_UNLOCK_DOOR, lock_request("2468"))
      locked_out_status = locked_out_result.as(Matter::InteractionModel::Status)
      locked_out_status.status.should eq(Matter::InteractionModel::StatusCode::Failure)
      locked_out_status.cluster_status.should eq(Def::StatusCode::Failure.value)

      sleep 1.2.seconds
      recovered_result = invoke(cluster, Matter::Cluster::DoorLock::CMD_UNLOCK_DOOR, lock_request("2468"))
      recovered_result.as(Matter::InteractionModel::Status).success?.should be_true
    end

    it "counts a provided empty PIN toward the wrong-code limit" do
      cluster = build(Def, require_pin_for_remote_operation: true,
        default_pin_code: "2468", wrong_code_entry_limit: 1_u8,
        user_code_temporary_disable_time: 1_u8)

      expect_status(invoke(cluster, Def::CMD_UNLOCK_DOOR, lock_request("")),
        Matter::InteractionModel::StatusCode::Failure)
      expect_status(invoke(cluster, Def::CMD_UNLOCK_DOOR, lock_request("2468")),
        Matter::InteractionModel::StatusCode::Failure)
      cluster.lock_state.should eq(Def::LockState::Locked)
    end

    it "rejects a provided empty PIN when a PIN is optional" do
      cluster = build(Def, require_pin_for_remote_operation: false,
        default_pin_code: "2468", wrong_code_entry_limit: 1_u8,
        user_code_temporary_disable_time: 1_u8)

      expect_status(invoke(cluster, Def::CMD_UNLOCK_DOOR, lock_request("")),
        Matter::InteractionModel::StatusCode::Failure)
      expect_status(invoke(cluster, Def::CMD_UNLOCK_DOOR, lock_request("2468")),
        Matter::InteractionModel::StatusCode::Failure)
      cluster.lock_state.should eq(Def::LockState::Locked)
    end

    it "denies an omitted required PIN without counting a presented credential" do
      cluster = build(Def, require_pin_for_remote_operation: true,
        default_pin_code: "2468", wrong_code_entry_limit: 1_u8,
        user_code_temporary_disable_time: 1_u8)

      expect_status(invoke(cluster, Def::CMD_UNLOCK_DOOR, lock_request),
        Matter::InteractionModel::StatusCode::Failure)
      expect_success(invoke(cluster, Def::CMD_UNLOCK_DOOR, lock_request("2468")))
    end
  end

  describe "user and credential commands" do
    it "supports setUser/getUser flow" do
      cluster = build(Matter::Cluster::DoorLock)

      set_user = Def::SetUserRequest.new(
        operation_type: Def::DataOperationType::Add,
        user_index: 2_u16,
        user_name: "Guest",
        user_unique_id: 222_u32,
        user_status: Def::UserStatus::OccupiedEnabled,
        user_type: Def::UserType::UnrestrictedUser,
        credential_rule: Def::CredentialRule::Single
      )

      set_result = invoke(cluster, Matter::Cluster::DoorLock::CMD_SET_USER, set_user)
      set_result.should be_a(Matter::InteractionModel::Status)
      set_result.as(Matter::InteractionModel::Status).success?.should be_true

      get_user = Def::GetUserRequest.new(user_index: 2_u16)
      get_result = invoke(cluster, Matter::Cluster::DoorLock::CMD_GET_USER, get_user)
      get_result.should be_a(Matter::Cluster::CommandResponse)

      response = get_result.as(Matter::Cluster::CommandResponse)
      response.command_id.should eq(Matter::Cluster::DoorLock::CMD_GET_USER_RESPONSE)

      parsed = Def::GetUserResponse.from_tlv(response.response.as(TLV::Any))
      parsed.user_index.should eq(2_u16)
      parsed.user_name.should eq("Guest")
      parsed.user_status.should eq(Def::UserStatus::OccupiedEnabled)
    end

    it "supports setCredential/getCredentialStatus flow" do
      cluster = build(Matter::Cluster::DoorLock)

      credential = Def::Credential.new(
        credential_type: Def::CredentialType::Pin,
        credential_index: 1_u16
      )

      set_credential = Def::SetCredentialRequest.new(
        operation_type: Def::DataOperationType::Add,
        credential: credential,
        credential_data: "1357".to_slice,
        user_index: 2_u16,
        user_status: Def::UserStatus::OccupiedEnabled,
        user_type: Def::UserType::UnrestrictedUser
      )

      set_result = invoke(cluster, Matter::Cluster::DoorLock::CMD_SET_CREDENTIAL, set_credential)
      set_result.should be_a(Matter::Cluster::CommandResponse)

      set_response = Def::SetCredentialResponse.from_tlv(set_result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      set_response.status_code.should eq(Def::StatusCode::Success)
      set_response.user_index.should eq(2_u16)

      get_status = Def::GetCredentialStatusRequest.new(credential: credential)
      get_result = invoke(cluster, Matter::Cluster::DoorLock::CMD_GET_CREDENTIAL_STATUS, get_status)
      get_result.should be_a(Matter::Cluster::CommandResponse)

      parsed = Def::GetCredentialStatusResponse.from_tlv(get_result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      parsed.credential_exists?.should be_true
      parsed.user_index.should eq(2_u16)
    end

    it "rejects credentials with out-of-range indexes" do
      cluster = build(Matter::Cluster::DoorLock,
        number_of_pin_users_supported: 2_u16
      )

      credential = Def::Credential.new(
        credential_type: Def::CredentialType::Pin,
        credential_index: 3_u16
      )

      request = Def::SetCredentialRequest.new(
        operation_type: Def::DataOperationType::Add,
        credential: credential,
        credential_data: "9999".to_slice,
        user_index: 2_u16,
        user_status: Def::UserStatus::OccupiedEnabled,
        user_type: Def::UserType::UnrestrictedUser
      )

      result = invoke(cluster, Matter::Cluster::DoorLock::CMD_SET_CREDENTIAL, request)
      result.should be_a(Matter::Cluster::CommandResponse)

      response = Def::SetCredentialResponse.from_tlv(result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any))
      response.status_code.should eq(Def::StatusCode::InvalidField)
    end
  end

  # A wired event callback is what production does (`Node` installs one), and
  # what every other spec here leaves nil. Emission serializes the payload, so a
  # field whose type TLV cannot encode turns a command into Failure only when a
  # journal is attached -- which is how lock/unlock reached chip-tool broken
  # while the unit suite stayed green.
  describe "event emission through a wired callback" do
    it "journals a LockOperation and still succeeds for a remote lock" do
      cluster = build(Matter::Cluster::DoorLock, require_pin_for_remote_operation: true, default_pin_code: "2468")
      emitted = [] of Tuple(UInt32, TLV::Any, UInt8?)
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _pr : Matter::InteractionModel::EventPriority, data : TLV::Any, fabric : UInt8?) do
        emitted << {event, data, fabric}
        nil
      end
      cluster.request_fabric_index = 1_u8
      cluster.request_peer_node_id = 0x1B669_u64

      request = Def::LockDoorRequest.new(pin_code: "2468".to_slice)
      expect_success(invoke(cluster, Matter::Cluster::DoorLock::CMD_LOCK_DOOR, request, fabric_index: 1_u8))

      emitted.size.should eq(1)
      event_id, payload, fabric = emitted.first
      event_id.should eq(Matter::Cluster::DoorLock::EVENT_LOCK_OPERATION)
      fabric.should eq(1_u8)

      decoded = Def::Events::LockOperation.from_tlv(payload)
      decoded.lock_operation_type.should eq(Def::LockOperationType::Lock)
      decoded.fabric_index.should eq(1_u8)
      decoded.source_node.should eq(0x1B669_u64)
    end

    it "journals a DoorStateChange" do
      cluster = build(Matter::Cluster::DoorLock, feature_map: Matter::Cluster::DoorLock::Feature::DoorPositionSensor)
      emitted = [] of UInt32
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _pr : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
        emitted << event
        nil
      end

      cluster.update_door_state(Def::DoorState::DoorOpen)

      emitted.should contain(Matter::Cluster::DoorLock::EVENT_DOOR_STATE_CHANGE)
    end
  end
end
