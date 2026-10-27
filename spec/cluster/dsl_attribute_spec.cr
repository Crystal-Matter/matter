require "../support/dsl_widget"

private alias Widget = DslSpec::Widget
private alias Privilege = Matter::InteractionModel::EntryPrivilege
private alias StatusCode = Matter::InteractionModel::StatusCode

private def widget(feature_map : Widget::Feature = Widget::Feature::None) : Widget
  build(Widget, feature_map: feature_map)
end

private def attribute_metadata(cluster : Widget, attribute_id : UInt32) : Matter::Cluster::AttributeMetadata
  cluster.get_attribute_metadata(attribute_id).as(Matter::Cluster::AttributeMetadata)
end

private def command_metadata(cluster : Widget, command_id : UInt32) : Matter::Cluster::CommandMetadata
  cluster.get_command_metadata(command_id).as(Matter::Cluster::CommandMetadata)
end

describe Matter::Cluster::DSL do
  describe "attribute" do
    it "generates the id constants" do
      Widget::ATTR_ENABLED.should eq(0x0000_u32)
      Widget::ATTR_LEVEL.should eq(0x0001_u32)
      Widget::ATTR_ALPHA_OR_BETA_WITHOUT_GAMMA.should eq(0x0009_u32)
    end

    it "generates the metadata" do
      cluster = widget
      names = cluster.attributes.map(&.name)
      names.should eq(%w[enabled level label mode offset setpoint serial notBeta secret counter guarded mirror uptime fabricView state raw store tag])

      level = attribute_metadata(cluster, Widget::ATTR_LEVEL)
      level.type.should eq(:uint8)
      level.writable?.should be_true
      level.optional?.should be_false
      level.fixed?.should be_false
      level.default.as(TLV::Any).as_u8.should eq(10_u8)
      level.min.should eq(1_i64)
      level.max.should eq(100_i64)
      level.access.should eq(Privilege::View)
      level.write_access.should eq(Privilege::View)
      level.timed?.should be_false
      level.scene?.should be_false

      attribute_metadata(cluster, Widget::ATTR_ENABLED).type.should eq(:bool)
      attribute_metadata(cluster, Widget::ATTR_LABEL).type.should eq(:string)
      attribute_metadata(cluster, Widget::ATTR_OFFSET).type.should eq(:int16)
      attribute_metadata(cluster, Widget::ATTR_OFFSET).min.should eq(-100_i64)
      attribute_metadata(cluster, Widget::ATTR_SETPOINT).type.should eq(:uint16)
      attribute_metadata(cluster, Widget::ATTR_SETPOINT).default.should be_nil

      mode = attribute_metadata(cluster, Widget::ATTR_MODE)
      mode.type.should eq(:enum)
      mode.default.as(TLV::Any).as_u8.should eq(DslSpec::Mode::Idle.value)

      counter = attribute_metadata(cluster, Widget::ATTR_COUNTER)
      counter.optional?.should be_true
      counter.scene?.should be_true
      counter.omit_changes?.should be_true
      counter.timed?.should be_true
      counter.fabric_scoped?.should be_true

      attribute_metadata(cluster, Widget::ATTR_SERIAL).fixed?.should be_true
      cluster.get_attribute_metadata(0x9999_u32).should be_nil
    end

    it "routes read_access: and write_access: to the metadata" do
      secret = attribute_metadata(widget, Widget::ATTR_SECRET)
      secret.access.should eq(Privilege::Operate)
      secret.write_access.should eq(Privilege::Manage)
    end

    it "generates typed getters" do
      cluster = widget
      cluster.enabled?.should be_false
      cluster.level.should eq(10_u8)
      cluster.label.should eq("widget")
      cluster.mode.should eq(DslSpec::Mode::Idle)
      cluster.setpoint.should be_nil
      cluster.serial.should eq("SN-1")
    end

    it "reads values as TLV" do
      cluster = widget
      read(cluster, Widget::ATTR_ENABLED).should be_false
      read(cluster, Widget::ATTR_LEVEL).should eq(10_u8)
      read(cluster, Widget::ATTR_LABEL).should eq("widget")
      read(cluster, Widget::ATTR_MODE).should eq(DslSpec::Mode::Idle.value)
      read(cluster, Widget::ATTR_OFFSET).should eq(0_i16)
      read(cluster, Widget::ATTR_SETPOINT).should be_nil
      read_status(cluster, 0x9999_u32).status.should eq(StatusCode::UnsupportedAttribute)
    end

    describe "setter" do
      it "copies opted-in arrays on assignment and read while preserving notifications" do
        cluster = build(DslSpec::CopiedList)
        input = [1_u8]

        changes = capture_changes(cluster) do
          version_delta(cluster) { cluster.items = input }.should eq(1)
        end
        changes.map(&.attribute).should eq([DslSpec::CopiedList::ATTR_ITEMS])

        input.clear
        cluster.items.should eq([1_u8])
        exposed = cluster.items
        exposed << 9_u8
        cluster.items.should eq([1_u8])
        read(cluster, DslSpec::CopiedList::ATTR_ITEMS).as(Array(TLV::Any)).map(&.value).should eq([1_u8])
        version_delta(cluster) { cluster.items = [1_u8] }.should eq(0)
        version_delta(cluster) { cluster.items = [2_u8] }.should eq(1)
        cluster.items.should eq([2_u8])
      end

      it "copies nullable arrays on assignment and read" do
        cluster = build(DslSpec::CopiedList)
        cluster.optional_items.should be_nil
        input = [4_u8]
        cluster.optional_items = input
        input.clear
        exposed = cluster.optional_items.as(Array(UInt8))
        exposed.clear
        cluster.optional_items.should eq([4_u8])
        cluster.optional_items = nil
        cluster.optional_items.should be_nil
      end

      it "ignores an equal value" do
        cluster = widget
        changes = capture_changes(cluster) do
          version_delta(cluster) { cluster.level = 10_u8 }.should eq(0)
        end
        changes.should be_empty
      end

      it "bumps the version, notifies and runs the (old, new) callback" do
        cluster = widget
        observed = [] of Tuple(UInt8, UInt8)
        cluster.on_level_changed { |old_value, new_value| observed << {old_value, new_value} }

        changes = capture_changes(cluster) do
          version_delta(cluster) { cluster.level = 20_u8 }.should eq(1)
        end

        changes.map(&.attribute).should eq([Widget::ATTR_LEVEL])
        changes[0].cluster.should eq(Widget::CLUSTER_ID)
        observed.should eq([{10_u8, 20_u8}])
        cluster.level.should eq(20_u8)
      end

      it "runs a callback: :new_only callback with the new value" do
        cluster = widget
        observed = [] of Bool
        cluster.on_enabled_changed { |value| observed << value }

        cluster.enabled = true
        cluster.enabled = true
        cluster.enabled = false

        observed.should eq([true, false])
      end
    end

    it "round trips a nullable attribute" do
      cluster = widget
      expect_success(write(cluster, Widget::ATTR_SETPOINT, 500_u16))
      read(cluster, Widget::ATTR_SETPOINT).should eq(500_u16)
      cluster.setpoint.should eq(500_u16)

      observed = [] of Tuple(UInt16?, UInt16?)
      cluster.on_setpoint_changed { |old_value, new_value| observed << {old_value, new_value} }
      changes = capture_changes(cluster) do
        version_delta(cluster) { expect_success(write(cluster, Widget::ATTR_SETPOINT, nil)) }.should eq(1)
      end
      changes.map(&.attribute).should eq([Widget::ATTR_SETPOINT])
      observed.should eq([{500_u16, nil}])
      read(cluster, Widget::ATTR_SETPOINT).should be_nil

      version_delta(cluster) { cluster.setpoint = nil }.should eq(0)
    end

    describe "writes" do
      it "rejects values outside min:/max: with ConstraintError" do
        cluster = widget
        expect_status(write(cluster, Widget::ATTR_LEVEL, 0_u8), StatusCode::ConstraintError)
        expect_status(write(cluster, Widget::ATTR_LEVEL, 101_u8), StatusCode::ConstraintError)
        cluster.level.should eq(10_u8)
        expect_success(write(cluster, Widget::ATTR_LEVEL, 100_u8))
        cluster.level.should eq(100_u8)

        expect_status(write(cluster, Widget::ATTR_OFFSET, -101_i16), StatusCode::ConstraintError)
        expect_success(write(cluster, Widget::ATTR_OFFSET, -100_i16))
        cluster.offset.should eq(-100_i16)
      end

      it "rejects strings longer than max_length: with ConstraintError" do
        cluster = widget
        expect_status(write(cluster, Widget::ATTR_LABEL, "too long!"), StatusCode::ConstraintError)
        cluster.label.should eq("widget")
        expect_success(write(cluster, Widget::ATTR_LABEL, "8 chars!"))
        cluster.label.should eq("8 chars!")
      end

      it "rejects an unknown enum member with ConstraintError" do
        cluster = widget
        expect_status(write(cluster, Widget::ATTR_MODE, DslSpec::Mode.values.size.to_u8), StatusCode::ConstraintError)
        cluster.mode.should eq(DslSpec::Mode::Idle)
        expect_success(write(cluster, Widget::ATTR_MODE, DslSpec::Mode::Fault.value))
        cluster.mode.should eq(DslSpec::Mode::Fault)
      end

      it "rejects the wrong TLV type with InvalidDataType" do
        cluster = widget
        expect_status(write(cluster, Widget::ATTR_LEVEL, "ten"), StatusCode::InvalidDataType)
        expect_status(write(cluster, Widget::ATTR_LEVEL, -1_i8), StatusCode::InvalidDataType)
        expect_status(write(cluster, Widget::ATTR_LABEL, 1_u8), StatusCode::InvalidDataType)
        expect_status(write(cluster, Widget::ATTR_MODE, "idle"), StatusCode::InvalidDataType)
        expect_status(write(cluster, Widget::ATTR_OFFSET, true), StatusCode::InvalidDataType)
        expect_status(write(cluster, Widget::ATTR_SETPOINT, "none"), StatusCode::InvalidDataType)
        cluster.data_version.should eq(0_u32)
      end

      it "rejects writes to read-only and fixed attributes with UnsupportedWrite" do
        cluster = widget
        expect_status(write(cluster, Widget::ATTR_ENABLED, true), StatusCode::UnsupportedWrite)
        expect_status(write(cluster, Widget::ATTR_SERIAL, "SN-2"), StatusCode::UnsupportedWrite)
        expect_status(write(cluster, 0x9999_u32, 1_u8), StatusCode::UnsupportedAttribute)
        cluster.serial.should eq("SN-1")
      end

      it "lets before_write reject and after_write react" do
        cluster = widget
        expect_status(write(cluster, Widget::ATTR_GUARDED, 3_u8), StatusCode::ConstraintError)
        cluster.guarded.should eq(0_u8)
        cluster.mirror.should eq(0_u8)

        expect_success(write(cluster, Widget::ATTR_GUARDED, 4_u8))
        cluster.guarded.should eq(4_u8)
        cluster.mirror.should eq(4_u8)
      end

      it "lets before_write replace the value" do
        cluster = widget
        expect_status(write(cluster, Widget::ATTR_TAG, ""), StatusCode::ConstraintError)
        cluster.tag.should eq("")

        expect_success(write(cluster, Widget::ATTR_TAG, "abc"))
        cluster.tag.should eq("ABC")
      end
    end
  end

  describe "computed:" do
    it "reads through the reader and has no storage" do
      cluster = widget
      cluster.uptime = 42_u32
      read(cluster, Widget::ATTR_UPTIME).should eq(42_u32)
      read(cluster, Widget::ATTR_STATE).should eq(DslSpec::Mode::Active.value)
      attribute_metadata(cluster, Widget::ATTR_UPTIME).default.should be_nil
      cluster.save_state.as(Matter::Storage::Document).keys.should_not contain("uptime")
      expect_status(write(cluster, Widget::ATTR_UPTIME, 1_u32), StatusCode::UnsupportedWrite)
    end

    it "passes the accessing fabric index to a reader taking one" do
      read_tlv(widget, Widget::ATTR_FABRIC_VIEW, 3_u8).as_list.map(&.as_u8).should eq([3_u8])
      read_tlv(widget, Widget::ATTR_FABRIC_VIEW).as_list.should be_empty
    end

    it "passes a reader's status or encoded value through" do
      cluster = widget
      read_status(cluster, Widget::ATTR_RAW).status.should eq(StatusCode::Failure)
      cluster.raw_ready = true
      read(cluster, Widget::ATTR_RAW).should eq(9_u8)
    end

    it "writes a writable computed attribute through its writer" do
      cluster = widget
      expect_status(write(cluster, Widget::ATTR_STORE, 51_u8), StatusCode::ConstraintError)
      expect_success(write(cluster, Widget::ATTR_STORE, 7_u8))
      cluster.store_value.should eq(7_u8)
      read(cluster, Widget::ATTR_STORE).should eq(7_u8)
    end
  end

  describe "present_if:" do
    it "gates on a nullable attribute having a value" do
      cluster = widget
      read_status(cluster, Widget::ATTR_MAYBE).status.should eq(StatusCode::UnsupportedAttribute)
      cluster.get_attribute_metadata(Widget::ATTR_MAYBE).should be_nil
      attribute_ids(cluster).should_not contain(Widget::ATTR_MAYBE)

      cluster.maybe = 5_u8
      read(cluster, Widget::ATTR_MAYBE).should eq(5_u8)
      attribute_ids(cluster).should contain(Widget::ATTR_MAYBE)
    end

    it "gates on a predicate method" do
      cluster = widget
      expect_status(write(cluster, Widget::ATTR_GATED, 1_u8), StatusCode::UnsupportedAttribute)
      attribute_ids(cluster).should_not contain(Widget::ATTR_GATED)

      cluster.gate_open = true
      expect_success(write(cluster, Widget::ATTR_GATED, 1_u8))
      read(cluster, Widget::ATTR_GATED).should eq(1_u8)
      attribute_ids(cluster).should contain(Widget::ATTR_GATED)
    end
  end

  describe "requires:" do
    it "gates a symbol condition" do
      cluster = widget
      read_status(cluster, Widget::ATTR_ALPHA_ONLY).status.should eq(StatusCode::UnsupportedAttribute)
      expect_status(write(cluster, Widget::ATTR_ALPHA_ONLY, 5_u8), StatusCode::UnsupportedAttribute)
      cluster.get_attribute_metadata(Widget::ATTR_ALPHA_ONLY).should be_nil
      attribute_ids(cluster).should_not contain(Widget::ATTR_ALPHA_ONLY)

      cluster = widget(Widget::Feature::Alpha)
      read(cluster, Widget::ATTR_ALPHA_ONLY).should eq(1_u8)
      expect_success(write(cluster, Widget::ATTR_ALPHA_ONLY, 5_u8))
      cluster.alpha_only.should eq(5_u8)
      attribute_ids(cluster).should contain(Widget::ATTR_ALPHA_ONLY)
    end

    it "gates a hash condition" do
      attribute_ids(widget).should contain(Widget::ATTR_NOT_BETA)
      attribute_ids(widget(Widget::Feature::Beta)).should_not contain(Widget::ATTR_NOT_BETA)
      read_status(widget(Widget::Feature::Beta), Widget::ATTR_NOT_BETA).status.should eq(StatusCode::UnsupportedAttribute)
    end

    it "gates an array of conditions as any-of" do
      attribute_ids(widget).should_not contain(Widget::ATTR_ALPHA_OR_BETA_WITHOUT_GAMMA)
      attribute_ids(widget(Widget::Feature::Alpha)).should contain(Widget::ATTR_ALPHA_OR_BETA_WITHOUT_GAMMA)
      attribute_ids(widget(Widget::Feature::Beta)).should contain(Widget::ATTR_ALPHA_OR_BETA_WITHOUT_GAMMA)
      attribute_ids(widget(Widget::Feature::Gamma)).should_not contain(Widget::ATTR_ALPHA_OR_BETA_WITHOUT_GAMMA)
      attribute_ids(widget(Widget::Feature::Alpha | Widget::Feature::Gamma)).should contain(Widget::ATTR_ALPHA_OR_BETA_WITHOUT_GAMMA)
    end

    it "accepts a constant" do
      attribute_ids(widget).should_not contain(Widget::ATTR_ALPHA_OR_BETA)
      attribute_ids(widget(Widget::Feature::Beta)).should contain(Widget::ATTR_ALPHA_OR_BETA)
    end

    it "gates events on features" do
      widget.events.map(&.name).should eq(%w[tripped noted])
      widget(Widget::Feature::Alpha).events.map(&.name).should eq(%w[tripped noted alphaEvent])
    end

    it "gates commands and the accepted command list" do
      cluster = widget
      expect_status(invoke(cluster, Widget::CMD_ALPHA_COMMAND), StatusCode::UnsupportedCommand)
      cluster.get_command_metadata(Widget::CMD_ALPHA_COMMAND).should be_nil
      accepted_command_ids(cluster).should_not contain(Widget::CMD_ALPHA_COMMAND)

      cluster = widget(Widget::Feature::Alpha)
      expect_success(invoke(cluster, Widget::CMD_ALPHA_COMMAND))
      accepted_command_ids(cluster).should contain(Widget::CMD_ALPHA_COMMAND)
    end

    it "lists the globals after the supported attributes" do
      attribute_ids(widget(Widget::Feature::Alpha)).should eq([
        Widget::ATTR_ENABLED, Widget::ATTR_LEVEL, Widget::ATTR_LABEL, Widget::ATTR_MODE, Widget::ATTR_OFFSET,
        Widget::ATTR_SETPOINT, Widget::ATTR_SERIAL, Widget::ATTR_ALPHA_ONLY, Widget::ATTR_NOT_BETA,
        Widget::ATTR_ALPHA_OR_BETA_WITHOUT_GAMMA, Widget::ATTR_SECRET, Widget::ATTR_COUNTER, Widget::ATTR_GUARDED,
        Widget::ATTR_MIRROR, Widget::ATTR_UPTIME, Widget::ATTR_FABRIC_VIEW, Widget::ATTR_STATE, Widget::ATTR_RAW,
        Widget::ATTR_STORE, Widget::ATTR_TAG, Widget::ATTR_ALPHA_OR_BETA,
        Matter::Cluster::Base::GLOBAL_GENERATED_COMMAND_LIST, Matter::Cluster::Base::GLOBAL_ACCEPTED_COMMAND_LIST,
        Matter::Cluster::Base::GLOBAL_EVENT_LIST,
        Matter::Cluster::Base::GLOBAL_ATTRIBUTE_LIST, Matter::Cluster::Base::GLOBAL_FEATURE_MAP,
        Matter::Cluster::Base::GLOBAL_CLUSTER_REVISION,
      ])
    end
  end
end
