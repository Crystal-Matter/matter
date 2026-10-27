require "./support/console"
require "./support/main"

# Synthetic closure with one independently positioned panel. The callbacks
# acknowledge actuator admission; a real host reports actual motion through
# report_state when its sensors observe completion.
module MatterClosure
  CLOSURE_ENDPOINT_ID = 1_u16
  PANEL_ENDPOINT_ID   = 2_u16

  EXAMPLE_PRODUCT_ID = 0x0230_u16

  alias Control = Matter::Cluster::ClosureControl
  alias Dimension = Matter::Cluster::ClosureDimension
  PANEL_TAG_NAMESPACE = 0x45_u8
  PANEL_LIFT_TAG      =    0_u8

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Closure",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_closure_storage.yml"

    endpoint CLOSURE_ENDPOINT_ID, device_type: Matter::DeviceType::CLOSURE do
      cluster Matter::Cluster::Identify, identify_type: Matter::Cluster::Identify::IdentifyType::Actuator
      cluster Control,
        feature_map: Control::Feature::Positioning | Control::Feature::Calibration,
        overall_current_state: Control::CurrentState.new,
        overall_target_state: Control::TargetState.new,
        as: :closure_control
    end

    endpoint PANEL_ENDPOINT_ID, device_type: Matter::DeviceType::CLOSURE_PANEL,
      parent_endpoint: CLOSURE_ENDPOINT_ID,
      tag_list: [Matter::Cluster::Descriptor::SemanticTag.new(nil, PANEL_TAG_NAMESPACE, PANEL_LIFT_TAG)] do
      cluster Dimension,
        feature_map: Dimension::Feature::Positioning | Dimension::Feature::Translation,
        resolution: 100_u16,
        step_value: 500_u16,
        current_state: Dimension::State.new,
        target_state: Dimension::State.new,
        as: :closure_dimension
    end

    protected def before_start : Nil
      closure_control.on_move_to { |_request| true }
      closure_control.on_stop { }
      closure_control.on_calibrate { true }
      closure_dimension.on_set_target { |_request| true }
      super
    end
  end
end

Examples.main("Synthetic Closure") { MatterClosure::Device.new }
