require "./support/console"
require "./support/main"
require "./support/motion_hold"

# Matter Motion Sensor Device Example
#
# - Presents as an Occupancy Sensor (endpoint 1)
# - Samples simulated motion every 10 seconds
module MatterMotionSensor
  class Device < Matter::Device
    include Examples::Console

    @motion_hold = MotionHold.new

    SAMPLE_INTERVAL = 10.seconds

    # How often a sample finds the room occupied.
    OCCUPIED_CHANCE_PERCENT = 35

    # The PIR sensor type bit of the OccupancySensorTypeBitmap.
    PIR_SENSOR_BITMAP = 0x01_u8

    identity vendor: "Spider-Gazelle", product: "Crystal Motion Sensor",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(Examples::RANDOM_PRODUCT_ID_RANGE),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::OCCUPANCY_SENSOR

    storage yaml: "matter_motion_sensor_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::OCCUPANCY_SENSOR do
      cluster Matter::Cluster::OccupancySensing,
        feature_map: Matter::Cluster::OccupancySensing::Feature::PassiveInfrared |
                     Matter::Cluster::OccupancySensing::Feature::OccupancyEvent,
        occupancy: Matter::Cluster::OccupancySensing::OCCUPANCY_UNOCCUPIED,
        occupancy_sensor_type: :pir,
        occupancy_sensor_type_bitmap: PIR_SENSOR_BITMAP,
        hold_time: 60_u16,
        as: :occupancy
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Example Motion")]
    end

    on(:occupancy, :occupancy_changed) do |_old_value, new_value|
      notify "Motion: #{new_value == Matter::Cluster::OccupancySensing::OCCUPANCY_OCCUPIED ? "occupied" : "clear"}"
    end

    def console_notes : Array(String)
      ["Device Type: Occupancy Sensor"]
    end

    def state_details : Nil
      puts "  Motion: #{motion_state}"
      puts "  Sample interval: #{SAMPLE_INTERVAL.total_seconds.to_i}s"
    end

    def status_details : Nil
      puts "  Motion: #{motion_state}"
    end

    def commands : Array(Tuple(String, String))
      [{"sample", "Sample motion now"}]
    end

    def handle_command(name : String, argument : String?) : Bool
      return false unless name == "sample"
      sample
      true
    end

    protected def on_started : Nil
      super
      every(SAMPLE_INTERVAL) { sample }
    end

    private def sample : Nil
      detected = rand(0..99) < OCCUPIED_CHANCE_PERCENT
      if state = @motion_hold.sample(detected, occupancy.hold_time || occupancy.pir_occupied_to_unoccupied_delay)
        occupancy.update_occupancy(state)
      end
    end

    private def motion_state : String
      occupancy.occupancy == Matter::Cluster::OccupancySensing::OCCUPANCY_OCCUPIED ? "occupied" : "clear"
    end
  end
end

Examples.main("Matter Motion Sensor Device") { MatterMotionSensor::Device.new }
