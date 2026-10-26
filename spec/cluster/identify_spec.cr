require "../spec_helper"
require "../../src/matter/cluster/identify"

# Helper to encode Identify command (tag 0 = IdentifyTime)
def encode_identify_command(time : UInt16) : TLV::Any
  Matter::Cluster::Identify::Request.new(time).to_tlv(nil)
end

# Helper to encode TriggerEffect command (tag 0 = EffectIdentifier, tag 1 = EffectVariant)
def encode_trigger_effect_command(effect : UInt8, variant : UInt8) : TLV::Any
  Matter::Cluster::Identify::TriggerEffectRequest.new(
    effect_identifier: Matter::Cluster::Identify::EffectIdentifier.new(effect),
    effect_variany: Matter::Cluster::Identify::EffectVariant.new(variant)
  ).to_tlv(nil)
end

describe Matter::Cluster::Identify do
  describe "initialization" do
    it "creates identify cluster" do
      cluster = build(Matter::Cluster::Identify)

      cluster.cluster_id.id.should eq(0x0003_u32)
      cluster.name.should eq("Identify")
      cluster.identify_time.should eq(0_u16)
      cluster.identify_type.should eq(Matter::Cluster::Identify::IdentifyType::None)
    end

    it "initializes with custom identify type" do
      cluster = build(Matter::Cluster::Identify,
        identify_type: Matter::Cluster::Identify::IdentifyType::VisibleLight
      )

      cluster.identify_type.should eq(Matter::Cluster::Identify::IdentifyType::VisibleLight)
    end
  end

  describe "attributes" do
    it "has required attributes" do
      cluster = build(Matter::Cluster::Identify)

      attributes = cluster.attributes
      attributes.should_not be_empty
      attributes.size.should be >= 2

      identify_time = attributes.find { |attr| attr.id.id == Matter::Cluster::Identify::ATTR_IDENTIFY_TIME }
      identify_time.should_not be_nil
      identify_time_attr = identify_time.as(Matter::Cluster::AttributeMetadata)
      identify_time_attr.name.should eq("identifyTime")
      identify_time_attr.type.should eq(:uint16)
      identify_time_attr.writable?.should be_true

      identify_type = attributes.find { |attr| attr.id.id == Matter::Cluster::Identify::ATTR_IDENTIFY_TYPE }
      identify_type.should_not be_nil
      identify_type_attr = identify_type.as(Matter::Cluster::AttributeMetadata)
      identify_type_attr.name.should eq("identifyType")
      identify_type_attr.writable?.should be_false
    end

    it "reads IdentifyTime attribute" do
      cluster = build(Matter::Cluster::Identify)

      read(cluster, Matter::Cluster::Identify::ATTR_IDENTIFY_TIME).should eq(0_u16)
    end

    it "reads IdentifyType attribute" do
      cluster = build(Matter::Cluster::Identify,
        identify_type: Matter::Cluster::Identify::IdentifyType::AudibleBeep
      )

      read(cluster, Matter::Cluster::Identify::ATTR_IDENTIFY_TYPE).should eq(Matter::Cluster::Identify::IdentifyType::AudibleBeep.value)
    end

    it "writes IdentifyTime attribute" do
      cluster = build(Matter::Cluster::Identify)

      # Encode 60 seconds as raw uint16
      status = write(cluster,
        Matter::Cluster::Identify::ATTR_IDENTIFY_TIME,
        60_u16
      )

      status.success?.should be_true
      cluster.identify_time.should eq(60_u16)
    end

    it "rejects writing to IdentifyType" do
      cluster = build(Matter::Cluster::Identify)

      status = write(cluster,
        Matter::Cluster::Identify::ATTR_IDENTIFY_TYPE,
        2_u16
      )

      status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    end
  end

  describe "commands" do
    it "has required commands" do
      cluster = build(Matter::Cluster::Identify)

      commands = cluster.commands
      commands.size.should eq(2)

      identify_cmd = commands.find { |cmd| cmd.id.id == Matter::Cluster::Identify::CMD_IDENTIFY }
      identify_cmd.should_not be_nil
      identify_cmd.as(Matter::Cluster::CommandMetadata).name.should eq("identify")
      identify_cmd.as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)

      trigger_effect_cmd = commands.find { |cmd| cmd.id.id == Matter::Cluster::Identify::CMD_TRIGGER_EFFECT }
      trigger_effect_cmd.should_not be_nil
      trigger_effect_cmd.as(Matter::Cluster::CommandMetadata).name.should eq("triggerEffect")
      trigger_effect_cmd.as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
    end

    it "executes Identify command" do
      cluster = build(Matter::Cluster::Identify)

      cluster.identify_time.should eq(0_u16)

      # Encode identify time (60 seconds) as TLV struct
      result = invoke(cluster,
        Matter::Cluster::Identify::CMD_IDENTIFY,
        encode_identify_command(60_u16)
      )

      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).success?.should be_true
      cluster.identify_time.should eq(60_u16)
    end

    it "executes TriggerEffect command" do
      cluster = build(Matter::Cluster::Identify)

      # Encode effect (Blink) and effect variant as TLV struct
      result = invoke(cluster,
        Matter::Cluster::Identify::CMD_TRIGGER_EFFECT,
        encode_trigger_effect_command(
          Matter::Cluster::Identify::EffectIdentifier::Blink.value,
          Matter::Cluster::Identify::EffectVariant::Default.value
        )
      )

      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).success?.should be_true
    end

    it "stops identify when time is 0" do
      cluster = build(Matter::Cluster::Identify)

      # Start identifying
      invoke(cluster, Matter::Cluster::Identify::CMD_IDENTIFY, encode_identify_command(10_u16))
      cluster.identify_time.should eq(10_u16)
      cluster.identifying?.should be_true

      # Stop identifying
      invoke(cluster, Matter::Cluster::Identify::CMD_IDENTIFY, encode_identify_command(0_u16))
      cluster.identify_time.should eq(0_u16)
      cluster.identifying?.should be_false
    end
  end

  describe "IdentifyType enum" do
    it "has all identify types" do
      Matter::Cluster::Identify::IdentifyType::None.value.should eq(0)
      Matter::Cluster::Identify::IdentifyType::VisibleLight.value.should eq(1)
      Matter::Cluster::Identify::IdentifyType::VisibleLED.value.should eq(2)
      Matter::Cluster::Identify::IdentifyType::AudibleBeep.value.should eq(3)
      Matter::Cluster::Identify::IdentifyType::Display.value.should eq(4)
      Matter::Cluster::Identify::IdentifyType::Actuator.value.should eq(5)
    end
  end

  describe "EffectIdentifier enum" do
    it "has all effect identifiers" do
      Matter::Cluster::Identify::EffectIdentifier::Blink.value.should eq(0)
      Matter::Cluster::Identify::EffectIdentifier::Breathe.value.should eq(1)
      Matter::Cluster::Identify::EffectIdentifier::Okay.value.should eq(2)
      Matter::Cluster::Identify::EffectIdentifier::ChannelChange.value.should eq(11)
      Matter::Cluster::Identify::EffectIdentifier::FinishEffect.value.should eq(254)
      Matter::Cluster::Identify::EffectIdentifier::StopEffect.value.should eq(255)
    end
  end

  describe "EffectVariant enum" do
    it "has effect variants" do
      Matter::Cluster::Identify::EffectVariant::Default.value.should eq(0)
    end
  end

  describe "identify state" do
    it "tracks identifying state" do
      cluster = build(Matter::Cluster::Identify)

      cluster.identifying?.should be_false

      invoke(cluster, Matter::Cluster::Identify::CMD_IDENTIFY, encode_identify_command(30_u16))
      cluster.identifying?.should be_true

      invoke(cluster, Matter::Cluster::Identify::CMD_IDENTIFY, encode_identify_command(0_u16))
      cluster.identifying?.should be_false
    end

    it "can check remaining identify time" do
      cluster = build(Matter::Cluster::Identify)

      invoke(cluster, Matter::Cluster::Identify::CMD_IDENTIFY, encode_identify_command(120_u16))
      cluster.identify_time.should eq(120_u16)
    end
  end

  describe "callbacks" do
    it "calls identify callback when started" do
      cluster = build(Matter::Cluster::Identify)

      callback_called = false
      cluster.on_identify_started do
        callback_called = true
      end

      invoke(cluster, Matter::Cluster::Identify::CMD_IDENTIFY, encode_identify_command(60_u16))
      callback_called.should be_true
    end

    it "calls identify callback when stopped" do
      cluster = build(Matter::Cluster::Identify)

      callback_called = false
      cluster.on_identify_stopped do
        callback_called = true
      end

      invoke(cluster, Matter::Cluster::Identify::CMD_IDENTIFY, encode_identify_command(60_u16))
      callback_called.should be_false # Not stopped yet

      invoke(cluster, Matter::Cluster::Identify::CMD_IDENTIFY, encode_identify_command(0_u16))
      callback_called.should be_true
    end

    it "calls effect callback on TriggerEffect" do
      cluster = build(Matter::Cluster::Identify)

      received_effect = Matter::Cluster::Identify::EffectIdentifier::Blink
      received_variant = Matter::Cluster::Identify::EffectVariant::Default

      cluster.on_trigger_effect do |effect, variant|
        received_effect = effect
        received_variant = variant
      end

      invoke(cluster,
        Matter::Cluster::Identify::CMD_TRIGGER_EFFECT,
        encode_trigger_effect_command(
          Matter::Cluster::Identify::EffectIdentifier::Breathe.value,
          Matter::Cluster::Identify::EffectVariant::Default.value
        )
      )

      received_effect.should eq(Matter::Cluster::Identify::EffectIdentifier::Breathe)
      received_variant.should eq(Matter::Cluster::Identify::EffectVariant::Default)
    end
  end

  describe "different identify types" do
    it "creates cluster for visible light device" do
      cluster = build(Matter::Cluster::Identify,
        identify_type: Matter::Cluster::Identify::IdentifyType::VisibleLight
      )

      cluster.identify_type.should eq(Matter::Cluster::Identify::IdentifyType::VisibleLight)
    end

    it "creates cluster for LED device" do
      cluster = build(Matter::Cluster::Identify,
        identify_type: Matter::Cluster::Identify::IdentifyType::VisibleLED
      )

      cluster.identify_type.should eq(Matter::Cluster::Identify::IdentifyType::VisibleLED)
    end

    it "creates cluster for audible device" do
      cluster = build(Matter::Cluster::Identify,
        identify_type: Matter::Cluster::Identify::IdentifyType::AudibleBeep
      )

      cluster.identify_type.should eq(Matter::Cluster::Identify::IdentifyType::AudibleBeep)
    end

    it "creates cluster for display device" do
      cluster = build(Matter::Cluster::Identify,
        identify_type: Matter::Cluster::Identify::IdentifyType::Display
      )

      cluster.identify_type.should eq(Matter::Cluster::Identify::IdentifyType::Display)
    end

    it "creates cluster for actuator device" do
      cluster = build(Matter::Cluster::Identify,
        identify_type: Matter::Cluster::Identify::IdentifyType::Actuator
      )

      cluster.identify_type.should eq(Matter::Cluster::Identify::IdentifyType::Actuator)
    end
  end

  describe "error handling" do
    it "returns error for unsupported attribute" do
      cluster = build(Matter::Cluster::Identify)

      read_status(cluster, 0x9999_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end

    it "returns error for unsupported command" do
      cluster = build(Matter::Cluster::Identify)

      result = invoke(cluster, 0x99_u32, Bytes.new(0))
      result.should be_a(Matter::InteractionModel::Status)
      result.as(Matter::InteractionModel::Status).status.should eq(
        Matter::InteractionModel::StatusCode::UnsupportedCommand
      )
    end
  end

  describe "data versioning" do
    it "increments version when identify time changes" do
      cluster = build(Matter::Cluster::Identify)

      initial_version = cluster.data_version

      invoke(cluster, Matter::Cluster::Identify::CMD_IDENTIFY, encode_identify_command(30_u16))
      cluster.data_version.should eq(initial_version + 1)
    end

    it "increments version when writing IdentifyTime" do
      cluster = build(Matter::Cluster::Identify)

      initial_version = cluster.data_version

      write(cluster,
        Matter::Cluster::Identify::ATTR_IDENTIFY_TIME,
        45_u16
      )

      cluster.data_version.should eq(initial_version + 1)
    end
  end
end
