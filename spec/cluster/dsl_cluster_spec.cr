require "../support/dsl_widget"

private alias Widget = DslSpec::Widget
private alias Privilege = Matter::InteractionModel::EntryPrivilege
private alias StatusCode = Matter::InteractionModel::StatusCode

private class PositionalEventWidget < Matter::Cluster::Base
  cluster 0xFFF1_FC50, revision: 1

  event 0x00, :managed, :info, nil, :manage
end

private def widget(feature_map : Widget::Feature = Widget::Feature::None) : Widget
  build(Widget, feature_map: feature_map)
end

private def attribute_metadata(cluster : Widget, attribute_id : UInt32) : Matter::Cluster::AttributeMetadata
  cluster.get_attribute_metadata(attribute_id).as(Matter::Cluster::AttributeMetadata)
end

private def command_metadata(cluster : Widget, command_id : UInt32) : Matter::Cluster::CommandMetadata
  cluster.get_command_metadata(command_id).as(Matter::Cluster::CommandMetadata)
end

# Compiles a fixture that must be rejected and returns the compiler output.
private def compile_fixture(name : String) : String
  crystal = Process.find_executable("crystal")
  pending! "the crystal compiler is not on PATH" unless crystal

  fixture = File.join(__DIR__, "..", "fixtures", name)
  output = IO::Memory.new
  status = Process.run(crystal, ["build", "--no-codegen", fixture], output: output, error: output)

  status.success?.should be_false
  output.to_s
end

describe Matter::Cluster::DSL do
  describe "cluster" do
    it "generates the id, revision and name" do
      Widget::CLUSTER_ID.should eq(0xFFF1_FC10_u32)
      Widget.cluster_id.should eq(Widget::CLUSTER_ID)
      Widget::CLUSTER_REVISION.should eq(3_u16)

      cluster = widget
      cluster.name.should eq("Widget")
      cluster.cluster_id.id.should eq(Widget::CLUSTER_ID)
      cluster.cluster_revision.should eq(3_u16)
      read(cluster, Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION).should eq(3_u16)
    end

    it "generates a constructor taking the feature map" do
      build(Widget, 2).feature_map.should eq(Widget::Feature::None)
      widget(Widget::Feature::Alpha).feature_map.alpha?.should be_true
    end

    it "takes name: and persist_state:" do
      gadget = build(DslSpec::Gadget)
      gadget.name.should eq("Renamed")
      gadget.knob = 3_u8
      gadget.save_state.should be_nil
      gadget.get_attribute_metadata(DslSpec::Gadget::ATTR_KNOB).as(Matter::Cluster::AttributeMetadata).writable?.should be_true
    end
  end

  describe "feature" do
    it "generates the Feature flags from the bit numbers" do
      Widget::Feature::Alpha.value.should eq(1_u32)
      Widget::Feature::Beta.value.should eq(2_u32)
      Widget::Feature::Gamma.value.should eq(4_u32)
      Widget::Feature::None.value.should eq(0_u32)
    end

    it "reports the feature map through the global attribute" do
      read(widget, Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(0_u32)
      read(widget(Widget::Feature::Alpha | Widget::Feature::Beta), Matter::Cluster::Base::GLOBAL_FEATURE_MAP).should eq(3_u32)
    end

    it "rejects conflicting features" do
      expect_raises(ArgumentError, /Widget cluster: Beta and Gamma features cannot be combined/) do
        widget(Widget::Feature::Beta | Widget::Feature::Gamma)
      end
    end
  end

  describe "command" do
    it "generates the id constants and metadata" do
      Widget::CMD_PING.should eq(0x00_u32)
      Widget::CMD_FALLIBLE.should eq(0x08_u32)

      cluster = widget
      cluster.commands.map(&.name).should eq(%w[ping reset implementedOptional guardedCommand echo fallible setThing whoami])

      ping = command_metadata(cluster, Widget::CMD_PING)
      ping.response_id.should eq(0x01_u32)
      ping.optional?.should be_false
      ping.timed?.should be_false
      ping.access.should eq(Privilege::Operate)

      command_metadata(cluster, Widget::CMD_RESET).response_id.should be_nil
      command_metadata(cluster, Widget::CMD_IMPLEMENTED_OPTIONAL).optional?.should be_true

      guarded = command_metadata(cluster, Widget::CMD_GUARDED_COMMAND)
      guarded.timed?.should be_true
      guarded.access.should eq(Privilege::Manage)
    end

    it "leaves an optional command without a handler out of the lists" do
      cluster = widget
      cluster.get_command_metadata(Widget::CMD_UNIMPLEMENTED).should be_nil
      accepted_command_ids(cluster).should eq([
        Widget::CMD_PING, Widget::CMD_RESET, Widget::CMD_IMPLEMENTED_OPTIONAL, Widget::CMD_GUARDED_COMMAND,
        Widget::CMD_ECHO, Widget::CMD_FALLIBLE, Widget::CMD_SET_THING, Widget::CMD_WHOAMI,
      ])
      expect_status(invoke(cluster, Widget::CMD_UNIMPLEMENTED), StatusCode::UnsupportedCommand)
      expect_status(invoke(cluster, 0x99_u32), StatusCode::UnsupportedCommand)
    end

    it "dispatches to handlers and passes status results through" do
      cluster = widget
      cluster.level = 42_u8
      expect_success(invoke(cluster, Widget::CMD_RESET))
      cluster.level.should eq(10_u8)
      expect_status(invoke(cluster, Widget::CMD_GUARDED_COMMAND), StatusCode::Busy)

      result = invoke(cluster, Widget::CMD_IMPLEMENTED_OPTIONAL)
      result.as(Matter::Cluster::CommandResponse).command_id.should eq(Widget::CMD_IMPLEMENTED_OPTIONAL)
    end

    it "wraps a returned struct as the response command" do
      cluster = widget
      result = invoke(cluster, Widget::CMD_PING, DslSpec::PingRequest.new(7_u8))
      response = result.as(Matter::Cluster::CommandResponse)
      response.command_id.should eq(0x01_u32)
      DslSpec::PingResponse.from_tlv(response.response.as(TLV::Any)).echoed.should eq(7_u8)

      invoke_response(cluster, Widget::CMD_FALLIBLE, DslSpec::PingRequest.new(3_u8), DslSpec::PingResponse).echoed.should eq(3_u8)
      expect_status(invoke(cluster, Widget::CMD_FALLIBLE, DslSpec::PingRequest.new(0_u8)), StatusCode::InvalidCommand)
    end

    it "rejects a request that does not decode with InvalidCommand" do
      expect_status(invoke(widget, Widget::CMD_PING), StatusCode::InvalidCommand)
      expect_status(invoke(widget, Widget::CMD_PING, TLV::Any.new("ping")), StatusCode::InvalidCommand)
    end

    it "derives the generated command list from the distinct response ids" do
      generated_command_ids(widget).should eq([0x01_u32, 0x09_u32])
    end

    it "generates the response command constants" do
      Widget::CMD_PING_RESPONSE.should eq(0x01_u32)
      Widget::CMD_FALLIBLE_RESPONSE.should eq(0x09_u32)
    end

    it "dispatches to handler: when given" do
      cluster = widget
      expect_success(invoke(cluster, Widget::CMD_SET_THING, DslSpec::PingRequest.new(3_u8)))
      cluster.level.should eq(3_u8)
    end

    it "exposes the request context to handlers" do
      cluster = widget
      expect_success(invoke(cluster, Widget::CMD_WHOAMI, session_id: 77_u64, is_case_session: true, fabric_index: 3_u8))
      cluster.seen_fabric.should eq(3_u8)
      cluster.seen_session.should eq(77_u64)
      cluster.seen_case?.should be_true

      expect_success(invoke(cluster, Widget::CMD_WHOAMI))
      cluster.seen_fabric.should be_nil
      cluster.seen_case?.should be_false
    end
  end

  describe "event" do
    it "preserves positional access arguments when adding presence gating" do
      build(PositionalEventWidget).events.first.access.should eq(Privilege::Manage)
    end

    it "generates the id constants and metadata" do
      Widget::EVENT_TRIPPED.should eq(0x00_u32)
      Widget::EVENT_NOTED.should eq(0x01_u32)

      events = widget.events
      events.map(&.name).should eq(%w[tripped noted])
      events.map(&.id.id).should eq([Widget::EVENT_TRIPPED, Widget::EVENT_NOTED])
      events.map(&.priority).should eq([Matter::InteractionModel::EventPriority::Critical, Matter::InteractionModel::EventPriority::Info])
    end
  end

  describe "persistence" do
    it "saves the persisted attributes with the feature map stamp" do
      cluster = widget(Widget::Feature::Alpha)
      cluster.level = 42_u8
      cluster.label = "abc"
      cluster.offset = -7_i16
      cluster.setpoint = 9_u16
      cluster.alpha_only = 5_u8
      cluster.counter = 77_u32
      cluster.mode = DslSpec::Mode::Active
      cluster.data_version = 12_u32

      document = cluster.save_state.as(Matter::Storage::Document)
      document.keys.sort!.should eq(%w[alpha_only counter data_version features gated label level offset setpoint tag])
      document["level"].should eq(42_i64)
      document["label"].should eq("abc")
      document["offset"].should eq(-7_i64)
      document["setpoint"].should eq(9_i64)
      document["alpha_only"].should eq(5_i64)
      document["counter"].should eq(77_i64)
      document["data_version"].should eq(12_i64)
      document["features"].should eq(Widget::Feature::Alpha.value.to_i64)

      restored = widget(Widget::Feature::Alpha)
      restored.restore_state(document)
      restored.level.should eq(42_u8)
      restored.label.should eq("abc")
      restored.offset.should eq(-7_i16)
      restored.setpoint.should eq(9_u16)
      restored.alpha_only.should eq(5_u8)
      restored.counter.should eq(77_u32)
      restored.data_version.should eq(12_u32)
      restored.mode.should eq(DslSpec::Mode::Idle)
    end

    it "discards state saved under a different feature map" do
      document = widget(Widget::Feature::Alpha).tap(&.level=(42_u8)).save_state.as(Matter::Storage::Document)

      restored = widget(Widget::Feature::Beta)
      restored.restore_state(document)
      restored.level.should eq(10_u8)
      restored.data_version.should eq(0_u32)
    end

    it "accepts state without a feature map stamp" do
      document = widget.tap(&.level=(42_u8)).save_state.as(Matter::Storage::Document)
      document.delete("features")

      restored = widget(Widget::Feature::Alpha)
      restored.restore_state(document)
      restored.level.should eq(42_u8)
    end

    it "starts fresh when the document does not decode" do
      document = widget.save_state.as(Matter::Storage::Document)
      document["level"] = "forty-two"

      restored = widget
      restored.level = 5_u8
      restored.restore_state(document)
      restored.level.should eq(5_u8)
    end
  end

  describe "compile-time checks" do
    it "rejects a mandatory command without a handler" do
      compile_fixture("dsl_missing_handler.cr").should contain("MissingHandlerCluster: command :unhandled has no handler method `unhandled`")
    end

    it "rejects a computed attribute without a reader" do
      compile_fixture("dsl_missing_reader.cr").should contain("MissingReaderCluster: computed attribute :elapsed has no reader method `elapsed`")
    end
  end
end
