require "./support/console"
require "./support/main"

# Synthetic closure with one independently positioned panel. The callbacks
# acknowledge actuator admission; a real host reports actual motion through
# report_state when its sensors observe completion.
module MatterClosure
  alias Control = Matter::Cluster::ClosureControl
  alias Dimension = Matter::Cluster::ClosureDimension

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Closure",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: 0x0230_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_closure_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::CLOSURE do
      cluster Matter::Cluster::Identify, identify_type: Matter::Cluster::Identify::IdentifyType::Actuator
      cluster Control,
        feature_map: Control::Feature::Positioning | Control::Feature::Calibration,
        overall_current_state: Control::CurrentState.new(Control::CurrentPosition::FullyClosed),
        as: :closure_control
    end

    endpoint 2, device_type: Matter::DeviceType::CLOSURE_PANEL do
      cluster Dimension,
        feature_map: Dimension::Feature::Positioning | Dimension::Feature::Translation,
        resolution: 100_u16,
        step_value: 500_u16,
        current_state: Dimension::State.new(0_u16),
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
