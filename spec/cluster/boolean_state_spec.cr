require "../spec_helper"
require "../../src/matter/cluster/boolean_state"

private alias BooleanState = Matter::Cluster::BooleanState

# Independent Matter 1.6 StateChange wire shape, context tag 0.
private struct BooleanStateChangeWire
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  getter? state_value : Bool

  def initialize(@state_value : Bool)
  end
end

describe Matter::Cluster::BooleanState do
  describe "initialization" do
    it "advertises revision 3 and ChangeEvent by default" do
      cluster = build(BooleanState)
      cluster.cluster_revision.should eq(3_u16)
      cluster.feature_map.value.should eq(1_u32)
      cluster.get_event_metadata(BooleanState::EVENT_STATE_CHANGE).should_not be_nil
    end

    it "creates with default false state" do
      cluster = build(BooleanState)

      cluster.cluster_id.id.should eq(0x0045_u32)
      cluster.name.should eq("BooleanState")
      cluster.state_value?.should be_false
    end

    it "creates with true state" do
      cluster = build(BooleanState, state_value: true)
      cluster.state_value?.should be_true
    end
  end

  describe "attributes" do
    it "exposes StateValue attribute metadata" do
      cluster = build(BooleanState)
      attrs = cluster.attributes

      attrs.size.should eq(1)
      attrs[0].id.id.should eq(BooleanState::ATTR_STATE_VALUE)
      attrs[0].name.should eq("stateValue")
      attrs[0].writable?.should be_false
    end

    it "reads state as TLV bool" do
      cluster = build(BooleanState, state_value: true)
      read(cluster, BooleanState::ATTR_STATE_VALUE).should be_true
    end

    it "returns unsupported for unknown attribute" do
      cluster = build(BooleanState)
      read_status(cluster, 0x9999_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end

  describe "update_state" do
    it "omits StateChange metadata and emission when ChangeEvent is disabled" do
      cluster = build(BooleanState, feature_map: BooleanState::Feature::None)
      events = [] of TLV::Any
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
        events << data
        nil
      end

      cluster.events.should be_empty
      cluster.get_event_metadata(BooleanState::EVENT_STATE_CHANGE).should be_nil
      cluster.update_state(true)
      cluster.state_value?.should be_true
      events.should be_empty
    end

    it "emits a typed StateChange event for direct setter changes, alongside callbacks" do
      cluster = build(BooleanState, state_value: false)
      changed = [] of Bool
      events = [] of TLV::Any
      cluster.on_state_changed { |_old, value| changed << value }
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, priority : Matter::InteractionModel::EventPriority, data : TLV::Any, fabric : UInt8?) do
        event.should eq(BooleanState::EVENT_STATE_CHANGE)
        priority.should eq(Matter::InteractionModel::EventPriority::Info)
        fabric.should be_nil
        events << data
        nil
      end

      cluster.state_value = true
      cluster.state_value = true
      cluster.update_state(false)

      changed.should eq([true, false])
      events.map { |data| BooleanStateChangeWire.from_tlv(data).state_value? }.should eq([true, false])
    end

    it "updates state and increments data version" do
      cluster = build(BooleanState, state_value: false)

      version_delta(cluster) { cluster.update_state(true) }.should eq(1)
      cluster.state_value?.should be_true
    end

    it "does not change data version when value is unchanged" do
      cluster = build(BooleanState, state_value: true)

      version_delta(cluster) { cluster.update_state(true) }.should eq(0)
    end

    it "invokes on_state_changed when value changes" do
      cluster = build(BooleanState, state_value: false)

      old_value : Bool? = nil
      new_value : Bool? = nil
      cluster.on_state_changed do |old, new|
        old_value = old
        new_value = new
      end

      cluster.update_state(true)

      old_value.should be_false
      new_value.should be_true
    end

    it "notifies attribute subscribers when value changes" do
      cluster = build(BooleanState, state_value: false)

      changes = capture_changes(cluster) { cluster.update_state(true) }

      changes.size.should eq(1)
      changes[0].endpoint.should eq(1_u16)
      changes[0].cluster.should eq(BooleanState::CLUSTER_ID)
      changes[0].attribute.should eq(BooleanState::ATTR_STATE_VALUE)
    end
  end
end
