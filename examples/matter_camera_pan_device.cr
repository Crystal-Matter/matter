require "./support/console"
require "./support/main"

# Synthetic pan actuator on an Aggregator endpoint, not a Camera device. A real camera starts its
# motor in the callback and calls report_pan_position from its sensor.
module MatterCameraPan
  DEVICE_ENDPOINT_ID = 1_u16

  EXAMPLE_PRODUCT_ID = 0x0552_u16

  alias CameraSettings = Matter::Cluster::CameraAvSettingsUserLevelManagement

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Pan Camera",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: EXAMPLE_PRODUCT_ID,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_camera_pan_storage.yml"

    endpoint DEVICE_ENDPOINT_ID, device_type: Matter::DeviceType::AGGREGATOR do
      cluster CameraSettings, pan_min: -90_i16, pan_max: 90_i16
    end

    protected def before_start : Nil
      pan = node.get_cluster!(DEVICE_ENDPOINT_ID, CameraSettings)
      pan.on_pan_move do |target|
        pan.report_pan_position(target)
        Matter::InteractionModel::Status.success
      end
      super
    end
  end
end

Examples.main("Synthetic Pan Camera") { MatterCameraPan::Device.new }
