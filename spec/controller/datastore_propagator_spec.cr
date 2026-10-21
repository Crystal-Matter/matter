require "../spec_helper"
require "../../src/matter/controller/datastore_propagator"

private class FlakyDatastoreDelivery < Matter::Controller::DatastorePropagator::Delivery
  getter attempts = 0

  def initialize(@failures_before_success : Int32)
  end

  def deliver(store : Matter::Cluster::JointFabricDatastore, node_id : UInt64) : Nil
    @attempts += 1
    if @attempts <= @failures_before_success
      raise Matter::TransportError.new("test connection failure")
    end
    store.complete_node(node_id)
  end
end

private class BlockingDatastoreDelivery < Matter::Controller::DatastorePropagator::Delivery
  def initialize(@started : Channel(Nil), @resume_delivery : Channel(Nil))
  end

  def deliver(store : Matter::Cluster::JointFabricDatastore, node_id : UInt64) : Nil
    @started.send(nil)
    @resume_delivery.receive
    store.complete_node(node_id)
  end
end

private def pending_datastore : Matter::Cluster::JointFabricDatastore
  store = Matter::Cluster::JointFabricDatastore.new(Matter::DataType::EndpointNumber.new(0_u16))
  pending = Matter::Cluster::JointFabricDatastore::DatastoreStatusEntryStruct.new(
    Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Pending, 0_u32, 0_u8
  )
  store.node_list = [Matter::Cluster::JointFabricDatastore::DatastoreNodeInformationEntryStruct.new(0x100_u64, "device", pending)]
  store
end

describe Matter::Controller::DatastorePropagator do
  it "drains the background worker before shutdown" do
    store = pending_datastore
    started = Channel(Nil).new
    resume_delivery = Channel(Nil).new
    delivery = BlockingDatastoreDelivery.new(started, resume_delivery)
    propagator = Matter::Controller::DatastorePropagator.new(store, delivery, poll_interval: 1.hour)
    propagator.start
    started.receive
    propagator.stop(1.millisecond).should be_false
    resume_delivery.send(nil)
    propagator.stop!
    propagator.stop!
    propagator.stop(1.second).should be_true
  end

  it "retries a transient connection failure and commits after delivery" do
    store = pending_datastore
    delivery = FlakyDatastoreDelivery.new(1)
    propagator = Matter::Controller::DatastorePropagator.new(store, delivery, max_attempts: 3, retry_delay: 0.seconds)

    propagator.run_pending

    delivery.attempts.should eq(2)
    store.node_list.first.commissioning_status_entry.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::Committed)
  end

  it "marks pending work failed after bounded attempts" do
    store = pending_datastore
    delivery = FlakyDatastoreDelivery.new(3)
    propagator = Matter::Controller::DatastorePropagator.new(store, delivery, max_attempts: 2, retry_delay: 0.seconds)

    propagator.run_pending

    delivery.attempts.should eq(2)
    store.node_list.first.commissioning_status_entry.state.should eq(Matter::Cluster::JointFabricDatastore::DatastoreStateEnum::CommitFailed)
  end
end
