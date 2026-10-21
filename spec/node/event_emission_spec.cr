require "../spec_helper"

private ENDPOINT_NUMBER = 1_u16

private def bridged_endpoint : Matter::Endpoint
  endpoint = Matter::Endpoint.new(endpoint(ENDPOINT_NUMBER))
  endpoint.add_cluster(build(Matter::Cluster::BridgedDeviceBasicInformation, ENDPOINT_NUMBER,
    node_label: "Bridged", unique_id: "event-bridged"
  ))
  endpoint
end

private def bridged_cluster(node : Matter::Node) : Matter::Cluster::BridgedDeviceBasicInformation
  node.get_cluster!(ENDPOINT_NUMBER, Matter::Cluster::BridgedDeviceBasicInformation)
end

describe "Cluster event emission" do
  describe Matter::Cluster::Base do
    describe "#emit_event" do
      it "raises for an event the cluster does not declare" do
        cluster = build(Matter::Cluster::OnOff, ENDPOINT_NUMBER)

        expect_raises(Matter::ConfigurationError, /does not declare event 0x0/) do
          cluster.emit_event(0_u32, TLV::Any.new(1_u32, nil))
        end
      end

      it "raises for an event gated off by the feature map" do
        cluster = build(Matter::Cluster::DoorLock, ENDPOINT_NUMBER,
          feature_map: Matter::Cluster::DoorLock::Feature::None
        )

        expect_raises(Matter::ConfigurationError, /does not declare event/) do
          cluster.emit_event(Matter::Cluster::DoorLock::EVENT_DOOR_STATE_CHANGE, TLV::Any.new(1_u32, nil))
        end
      end

      it "hands the declared priority and the fabric to the callback" do
        cluster = build(Matter::Cluster::BasicInformation, 0)

        seen = [] of Tuple(UInt16, UInt32, UInt32, Matter::InteractionModel::EventPriority, UInt8?)
        cluster.on_event_emitted = ->(endpoint : UInt16, cluster_id : UInt32, event : UInt32, priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, fabric : UInt8?) do
          seen << {endpoint, cluster_id, event, priority, fabric}
          nil
        end

        cluster.emit_leave_event(4_u8)

        seen.size.should eq(1)
        endpoint, cluster_id, event, priority, fabric = seen.first
        endpoint.should eq(0_u16)
        cluster_id.should eq(Matter::Cluster::BasicInformation::CLUSTER_ID)
        event.should eq(Matter::Cluster::BasicInformation::EVENT_LEAVE)
        priority.info?.should be_true
        fabric.should eq(4_u8)
      end
    end

    describe "declared event metadata" do
      it "carries the declared priority and the default read privilege" do
        cluster = build(Matter::Cluster::BasicInformation, 0)

        start_up = cluster.get_event_metadata(Matter::Cluster::BasicInformation::EVENT_START_UP).as(Matter::Cluster::EventMetadata)
        start_up.priority.critical?.should be_true
        start_up.access.view?.should be_true
        start_up.name.should eq("startUp")

        cluster.get_event_metadata(0x99_u32).should be_nil
      end
    end
  end

  describe Matter::Node do
    it "journals BooleanState ChangeEvent payloads after a direct state setter change" do
      node = Matter::Node.new
      contact_endpoint = Matter::Endpoint.new(endpoint(ENDPOINT_NUMBER))
      contact = build(Matter::Cluster::BooleanState, ENDPOINT_NUMBER)
      contact_endpoint.add_cluster(contact)
      node.add_endpoint(contact_endpoint)

      contact.state_value = true
      contact.state_value = true

      records = node.event_journal.query([Matter::InteractionModel::EventPath.new(
        cluster: Matter::Cluster::BooleanState::CLUSTER_ID,
        event: Matter::Cluster::BooleanState::EVENT_STATE_CHANGE,
      )])
      records.size.should eq(1)
      records.first.priority.info?.should be_true
      Matter::Cluster::BooleanState::StateChangeEvent.from_tlv(records.first.data).state_value?.should be_true
    end

    it "journals every event a cluster on the node emits" do
      node = Matter::Node.new
      node.add_endpoint(bridged_endpoint)

      bridged_cluster(node).emit_reachable_changed_event(false)

      node.event_journal.size.should eq(1)
      record = node.event_journal.query([Matter::InteractionModel::EventPath.new]).first
      record.endpoint.should eq(ENDPOINT_NUMBER)
      record.cluster.should eq(Matter::Cluster::BridgedDeviceBasicInformation::CLUSTER_ID)
      record.event.should eq(Matter::Cluster::BridgedDeviceBasicInformation::EVENT_REACHABLE_CHANGED)
      record.priority.info?.should be_true
    end

    it "hands the journaled record to the node observer" do
      node = Matter::Node.new
      observed = [] of Matter::EventJournal::Record
      node.on_event_emitted = ->(record : Matter::EventJournal::Record) do
        observed << record
        nil
      end
      node.add_endpoint(bridged_endpoint)

      bridged_cluster(node).emit_shut_down_event

      observed.size.should eq(1)
      observed.first.event.should eq(Matter::Cluster::BridgedDeviceBasicInformation::EVENT_SHUT_DOWN)
      observed.first.priority.critical?.should be_true
    end

    it "unwires a cluster when its endpoint is removed" do
      node = Matter::Node.new
      node.add_endpoint(bridged_endpoint)
      cluster = bridged_cluster(node)

      node.remove_endpoint(ENDPOINT_NUMBER)
      cluster.on_event_emitted.should be_nil

      cluster.emit_shut_down_event
      node.event_journal.size.should eq(0)
    end
  end

  describe Matter::Cluster::DoorLock do
    it "emits a LockOperation event for a remote lock and unlock" do
      node = Matter::Node.new
      endpoint = Matter::Endpoint.new(endpoint(ENDPOINT_NUMBER))
      lock = build(Matter::Cluster::DoorLock, ENDPOINT_NUMBER)
      endpoint.add_cluster(lock)
      node.add_endpoint(endpoint)

      lock.unlock(pin: lock.default_pin_code).success?.should be_true
      lock.lock(pin: lock.default_pin_code).success?.should be_true

      records = node.event_journal.query([Matter::InteractionModel::EventPath.new(
        cluster: Matter::Cluster::DoorLock::CLUSTER_ID,
        event: Matter::Cluster::DoorLock::EVENT_LOCK_OPERATION
      )])
      records.size.should eq(2)
      records.each(&.priority.critical?.should be_true)

      operations = records.map do |record|
        Matter::Cluster::DoorLock::Events::LockOperation.new(record.data).lock_operation_type
      end
      operations.should eq([
        Matter::Cluster::DoorLock::LockOperationType::Unlock,
        Matter::Cluster::DoorLock::LockOperationType::Lock,
      ])
    end

    it "emits a DoorStateChange event when the door position sensor reports" do
      node = Matter::Node.new
      endpoint = Matter::Endpoint.new(endpoint(ENDPOINT_NUMBER))
      lock = build(Matter::Cluster::DoorLock, ENDPOINT_NUMBER)
      endpoint.add_cluster(lock)
      node.add_endpoint(endpoint)

      lock.update_door_state(Matter::Cluster::DoorLock::DoorState::DoorOpen)

      records = node.event_journal.query([Matter::InteractionModel::EventPath.new(
        event: Matter::Cluster::DoorLock::EVENT_DOOR_STATE_CHANGE
      )])
      records.size.should eq(1)
      Matter::Cluster::DoorLock::Events::DoorStateChange.new(records.first.data).door_state
        .should eq(Matter::Cluster::DoorLock::DoorState::DoorOpen)
    end
  end
end
