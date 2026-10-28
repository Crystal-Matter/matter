require "../spec_helper"
require "../../src/matter/controller/datastore_propagator"
require "../../src/matter/storage/memory"

private class CounterReservationDelivery < Matter::Controller::DatastorePropagator::NetworkDelivery
  def reserve_for_spec(fabric : Matter::Controller::FabricInfo) : {UInt32, UInt32}
    reserve_case_counters(fabric)
  end
end

private def counter_reservation_fabric : Matter::Controller::FabricInfo
  Matter::Controller::FabricInfo.new(
    fabric_id: 0x1111_u64,
    controller_node_id: 0x2222_u64,
    ipk_value: Bytes.new(16, 0xAA_u8),
    root_cert: Bytes.empty,
    root_public_key: Bytes.empty,
    controller_noc: Bytes.empty,
    controller_private_key: Bytes.empty,
    admin_vendor_id: 0xFFF1_u16
  )
end

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
  it "gives two simultaneous network deliveries distinct CASE counter ranges" do
    state_store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = counter_reservation_fabric
    deliveries = [CounterReservationDelivery.new(state_store), CounterReservationDelivery.new(state_store)]
    reservations = Channel(Tuple(UInt32, UInt32)).new

    deliveries.each do |delivery|
      spawn { reservations.send(delivery.reserve_for_spec(fabric)) }
    end

    first = reservations.receive
    second = reservations.receive
    [first, second].sort_by { |reservation| reservation[0] }.should eq([{0_u32, 12_u32}, {12_u32, 12_u32}])
    state_store.load.unsecured_message_counter.should eq(24_u32)
  end

  it "reserves Sigma1 and completion counters for every CASE IPK candidate" do
    state_store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    fabric = counter_reservation_fabric
    fabric.ipk_epoch_keys = [Bytes.new(16, 0xA1_u8), Bytes.new(16, 0xA2_u8), Bytes.new(16, 0xA3_u8)]
    delivery = CounterReservationDelivery.new(state_store)

    delivery.reserve_for_spec(fabric).should eq({0_u32, 36_u32})
    state_store.load.unsecured_message_counter.should eq(36_u32)
  end

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
