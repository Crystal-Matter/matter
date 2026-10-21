require "../spec_helper"

describe Matter::Cluster::PowerSource do
  describe "initialization" do
    it "creates with default values (Battery feature)" do
      cluster = build(Matter::Cluster::PowerSource)
      cluster.status.should eq(Matter::Cluster::PowerSource::PowerSourceStatus::Active)
      cluster.order.should eq(0_u8)
      cluster.description.should eq("Battery")
      cluster.feature_map.should eq(Matter::Cluster::PowerSource::Feature::Battery)
      cluster.battery_feature_enabled?.should be_true
      cluster.replaceable_feature_enabled?.should be_false
    end

    it "creates with no features" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None
      )
      cluster.battery_feature_enabled?.should be_false
      cluster.replaceable_feature_enabled?.should be_false
    end

    it "creates with Battery feature (from matter.js test)" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        status: Matter::Cluster::PowerSource::PowerSourceStatus::Active,
        order: 1_u8,
        description: "aa batteries",
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )
      cluster.status.should eq(Matter::Cluster::PowerSource::PowerSourceStatus::Active)
      cluster.order.should eq(1_u8)
      cluster.description.should eq("aa batteries")
      cluster.bat_charge_level.should eq(Matter::Cluster::PowerSource::BatChargeLevel::Ok)
      cluster.bat_replacement_needed?.should be_false
      cluster.bat_replaceability.should eq(Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable)
      cluster.battery_feature_enabled?.should be_true
    end

    it "creates with Replaceable feature (from matter.js test)" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery | Matter::Cluster::PowerSource::Feature::Replaceable,
        status: Matter::Cluster::PowerSource::PowerSourceStatus::Active,
        order: 1_u8,
        description: "aa batteries",
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable,
        bat_replacement_description: "open, replace",
        bat_quantity: 2_u8
      )
      cluster.bat_replacement_description.should eq("open, replace")
      cluster.bat_quantity.should eq(2_u8)
      cluster.battery_feature_enabled?.should be_true
      cluster.replaceable_feature_enabled?.should be_true
    end

    it "validates description length" do
      expect_raises(ArgumentError, /description must be <= 60 characters/) do
        build(Matter::Cluster::PowerSource,
          description: "a" * 61
        )
      end
    end

    it "validates bat_replacement_description length" do
      expect_raises(ArgumentError, /bat_replacement_description must be <= 60 characters/) do
        build(Matter::Cluster::PowerSource,
          feature_map: Matter::Cluster::PowerSource::Feature::Battery | Matter::Cluster::PowerSource::Feature::Replaceable,
          bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
          bat_replacement_needed: false,
          bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable,
          bat_replacement_description: "a" * 61,
          bat_quantity: 2_u8
        )
      end
    end

    it "validates Battery feature completeness" do
      expect_raises(ArgumentError, /Battery feature requires/) do
        build(Matter::Cluster::PowerSource,
          feature_map: Matter::Cluster::PowerSource::Feature::Battery,
          bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok
          # Missing bat_replacement_needed and bat_replaceability
        )
      end
    end

    it "validates Replaceable feature requires Battery feature" do
      expect_raises(ArgumentError, /Replaceable feature requires Battery feature/) do
        build(Matter::Cluster::PowerSource,
          feature_map: Matter::Cluster::PowerSource::Feature::Replaceable,
          bat_replacement_description: "open, replace",
          bat_quantity: 2_u8
        )
      end
    end

    it "validates Replaceable feature completeness" do
      expect_raises(ArgumentError, /Replaceable feature requires/) do
        build(Matter::Cluster::PowerSource,
          feature_map: Matter::Cluster::PowerSource::Feature::Battery | Matter::Cluster::PowerSource::Feature::Replaceable,
          bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
          bat_replacement_needed: false,
          bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable,
          bat_replacement_description: "open, replace"
          # Missing bat_quantity
        )
      end
    end

    it "validates Wired and Battery are mutually exclusive" do
      expect_raises(ArgumentError, /Wired and Battery features cannot be combined/) do
        build(Matter::Cluster::PowerSource,
          feature_map: Matter::Cluster::PowerSource::Feature::Wired | Matter::Cluster::PowerSource::Feature::Battery
        )
      end
    end
  end

  describe "attributes" do
    it "always exposes the mandatory Matter 1.6 EndpointList" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None
      )
      cluster.attributes.map(&.name).should contain("endpointList")
      read_tlv(cluster, 0x001F_u32).as_list.should be_empty
    end

    it "reads and updates the endpoints supplied by this power source" do
      endpoints = [1_u16, 3_u16]
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None,
        endpoint_list: endpoints
      )
      endpoints << 5_u16
      read_tlv(cluster, Matter::Cluster::PowerSource::ATTR_ENDPOINT_LIST).as_list.map(&.as_u16).should eq([1_u16, 3_u16])

      replacement = [2_u16]
      cluster.update_endpoint_list(replacement)
      replacement << 4_u16
      read_tlv(cluster, Matter::Cluster::PowerSource::ATTR_ENDPOINT_LIST).as_list.map(&.as_u16).should eq([2_u16])
      write(cluster, Matter::Cluster::PowerSource::ATTR_ENDPOINT_LIST, [3_u16]).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
      expect_raises(ArgumentError, /duplicates/) { cluster.update_endpoint_list([2_u16, 2_u16]) }
    end

    it "has base attributes only when no features enabled" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None
      )
      attrs = cluster.attributes
      attrs.size.should eq(4)
      attrs.map(&.name).should contain("status")
      attrs.map(&.name).should contain("order")
      attrs.map(&.name).should contain("description")
      attrs.map(&.name).should contain("endpointList")
    end

    it "has Battery feature attributes when enabled" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )
      attrs = cluster.attributes
      attrs.size.should eq(7)
      attrs.map(&.name).should contain("batChargeLevel")
      attrs.map(&.name).should contain("batReplacementNeeded")
      attrs.map(&.name).should contain("batReplaceability")
    end

    it "has Replaceable feature attributes when enabled" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery | Matter::Cluster::PowerSource::Feature::Replaceable,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable,
        bat_replacement_description: "open, replace",
        bat_quantity: 2_u8
      )
      attrs = cluster.attributes
      attrs.size.should eq(9)
      attrs.map(&.name).should contain("batReplacementDescription")
      attrs.map(&.name).should contain("batQuantity")
    end

    it "reads the global FeatureMap with the configured features" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )
      # BAT feature bit — controllers use this (with an Active status) to
      # decide the node is battery powered.
      read(cluster, 0xFFFC_u32).should eq(2_u32)
    end

    it "reads a FeatureMap of zero when no features are enabled" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None
      )
      read(cluster, 0xFFFC_u32).should eq(0_u32)
    end

    it "reads Status" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None,
        status: Matter::Cluster::PowerSource::PowerSourceStatus::Standby
      )
      read(cluster, Matter::Cluster::PowerSource::ATTR_STATUS).should eq(2_u8) # Standby = 2
    end

    it "reads Order" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None,
        order: 5_u8
      )
      read(cluster, Matter::Cluster::PowerSource::ATTR_ORDER).should eq(5_u8)
    end

    it "reads Description" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None,
        description: "DC Power"
      )
      read(cluster, Matter::Cluster::PowerSource::ATTR_DESCRIPTION).should eq("DC Power")
    end

    it "reads BatChargeLevel when Battery feature enabled" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Warning,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )
      read(cluster, Matter::Cluster::PowerSource::ATTR_BAT_CHARGE_LEVEL).should eq(1_u8) # Warning = 1
    end

    it "reads BatReplacementNeeded" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: true,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )
      read(cluster, Matter::Cluster::PowerSource::ATTR_BAT_REPLACEMENT_NEEDED).should be_true
    end

    it "reads BatReplaceability" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::FactoryReplaceable
      )
      read(cluster, Matter::Cluster::PowerSource::ATTR_BAT_REPLACEABILITY).should eq(3_u8) # FactoryReplaceable = 3
    end

    it "reads BatReplacementDescription when Replaceable feature enabled" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery | Matter::Cluster::PowerSource::Feature::Replaceable,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable,
        bat_replacement_description: "2x AA",
        bat_quantity: 2_u8
      )
      read(cluster, Matter::Cluster::PowerSource::ATTR_BAT_REPLACEMENT_DESCRIPTION).should eq("2x AA")
    end

    it "reads BatQuantity" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery | Matter::Cluster::PowerSource::Feature::Replaceable,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable,
        bat_replacement_description: "2x AA",
        bat_quantity: 2_u8
      )
      read(cluster, Matter::Cluster::PowerSource::ATTR_BAT_QUANTITY).should eq(2_u8)
    end

    it "returns unsupported for Battery attributes when feature not enabled" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None
      )
      read_status(cluster, Matter::Cluster::PowerSource::ATTR_BAT_CHARGE_LEVEL).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end

    it "returns unsupported for Replaceable attributes when feature not enabled" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )
      read_status(cluster, Matter::Cluster::PowerSource::ATTR_BAT_REPLACEMENT_DESCRIPTION).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end

  describe "update methods" do
    it "updates battery percent remaining and increments the data version" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_percent_remaining: 200_u8,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      initial_version = cluster.data_version
      cluster.update_bat_percent_remaining(124_u8)
      cluster.bat_percent_remaining.should eq(124_u8)
      cluster.data_version.should eq(initial_version + 1)

      # unchanged value does not bump the version
      cluster.update_bat_percent_remaining(124_u8)
      cluster.data_version.should eq(initial_version + 1)

      # nil marks the level unknown
      cluster.update_bat_percent_remaining(nil)
      cluster.bat_percent_remaining.should be_nil
      cluster.data_version.should eq(initial_version + 2)
    end

    it "validates the half-percent range when updating percent remaining" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_percent_remaining: 100_u8,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      expect_raises(ArgumentError, /200/) do
        cluster.update_bat_percent_remaining(201_u8)
      end
    end

    it "ignores percent remaining updates when the Battery feature is disabled" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None
      )

      cluster.update_bat_percent_remaining(124_u8)
      cluster.bat_percent_remaining.should be_nil
    end

    it "updates battery charge level" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      cluster.update_bat_charge_level(Matter::Cluster::PowerSource::BatChargeLevel::Warning)
      cluster.bat_charge_level.should eq(Matter::Cluster::PowerSource::BatChargeLevel::Warning)
    end

    it "calls callback when charge level changes" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      old_level = nil.as(Matter::Cluster::PowerSource::BatChargeLevel??)
      new_level = nil.as(Matter::Cluster::PowerSource::BatChargeLevel?)
      cluster.on_charge_level_changed do |old, new|
        old_level = old
        new_level = new
      end

      cluster.update_bat_charge_level(Matter::Cluster::PowerSource::BatChargeLevel::Critical)
      old_level.should eq(Matter::Cluster::PowerSource::BatChargeLevel::Ok)
      new_level.should eq(Matter::Cluster::PowerSource::BatChargeLevel::Critical)
    end

    it "updates battery replacement needed" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      cluster.update_bat_replacement_needed(true)
      cluster.bat_replacement_needed?.should be_true
    end

    it "calls callback when replacement needed changes" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      old_needed = nil.as(Bool??)
      new_needed = nil.as(Bool?)
      cluster.on_replacement_needed_changed do |old, new|
        old_needed = old
        new_needed = new
      end

      cluster.update_bat_replacement_needed(true)
      old_needed.should be_false
      new_needed.should be_true
    end

    it "increments data version on change" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      initial_version = cluster.data_version
      cluster.update_bat_charge_level(Matter::Cluster::PowerSource::BatChargeLevel::Warning)
      cluster.data_version.should eq(initial_version + 1)
    end

    it "doesn't increment version if value unchanged" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      initial_version = cluster.data_version
      cluster.update_bat_charge_level(Matter::Cluster::PowerSource::BatChargeLevel::Ok)
      cluster.data_version.should eq(initial_version)
    end
  end

  describe "practical scenarios" do
    it "models AA battery powered sensor (from matter.js test)" do
      sensor = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery | Matter::Cluster::PowerSource::Feature::Replaceable,
        status: Matter::Cluster::PowerSource::PowerSourceStatus::Active,
        order: 1_u8,
        description: "aa batteries",
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable,
        bat_replacement_description: "open, replace",
        bat_quantity: 2_u8
      )

      sensor.battery_feature_enabled?.should be_true
      sensor.replaceable_feature_enabled?.should be_true
      sensor.status.should eq(Matter::Cluster::PowerSource::PowerSourceStatus::Active)
      sensor.bat_quantity.should eq(2_u8)
    end

    it "models rechargeable battery device" do
      device = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        status: Matter::Cluster::PowerSource::PowerSourceStatus::Active,
        order: 0_u8,
        description: "Lithium-ion battery",
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::NotReplaceable
      )

      device.bat_replaceability.should eq(Matter::Cluster::PowerSource::BatReplaceability::NotReplaceable)
    end

    it "models battery monitoring with charge level changes" do
      monitor = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      changes = [] of String
      monitor.on_charge_level_changed do |old, new|
        changes << "#{old} -> #{new}"
      end

      # Battery drains over time
      monitor.update_bat_charge_level(Matter::Cluster::PowerSource::BatChargeLevel::Warning)
      monitor.update_bat_charge_level(Matter::Cluster::PowerSource::BatChargeLevel::Critical)

      changes.should eq([
        "Ok -> Warning",
        "Warning -> Critical",
      ])
    end

    it "models battery replacement workflow" do
      device = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery | Matter::Cluster::PowerSource::Feature::Replaceable,
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Critical,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable,
        bat_replacement_description: "Replace with 2x AA alkaline",
        bat_quantity: 2_u8
      )

      # Mark battery for replacement
      device.update_bat_replacement_needed(true)
      device.bat_replacement_needed?.should be_true
      device.bat_replacement_description.should eq("Replace with 2x AA alkaline")

      # After replacement (simulated by creating new state)
      device.update_bat_charge_level(Matter::Cluster::PowerSource::BatChargeLevel::Ok)
      device.update_bat_replacement_needed(false)
      device.bat_replacement_needed?.should be_false
    end

    it "models device with primary and backup batteries" do
      # Primary battery (order 0 - preferred)
      primary = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        status: Matter::Cluster::PowerSource::PowerSourceStatus::Active,
        order: 0_u8,
        description: "Primary battery",
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      # Backup battery (order 1 - fallback)
      backup = build(Matter::Cluster::PowerSource, 2,
        feature_map: Matter::Cluster::PowerSource::Feature::Battery,
        status: Matter::Cluster::PowerSource::PowerSourceStatus::Standby,
        order: 1_u8,
        description: "Backup battery",
        bat_charge_level: Matter::Cluster::PowerSource::BatChargeLevel::Ok,
        bat_replacement_needed: false,
        bat_replaceability: Matter::Cluster::PowerSource::BatReplaceability::UserReplaceable
      )

      primary.order.should be < backup.order
      primary.status.should eq(Matter::Cluster::PowerSource::PowerSourceStatus::Active)
      backup.status.should eq(Matter::Cluster::PowerSource::PowerSourceStatus::Standby)
    end
  end

  describe "error handling" do
    it "returns error for unsupported attribute reads" do
      cluster = build(Matter::Cluster::PowerSource,
        feature_map: Matter::Cluster::PowerSource::Feature::None
      )
      read_status(cluster, 0x9999_u32).status.should eq(Matter::InteractionModel::StatusCode::UnsupportedAttribute)
    end
  end
end
