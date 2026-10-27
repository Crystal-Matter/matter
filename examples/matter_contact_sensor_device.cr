require "./support/console"
require "./support/main"

# Matter Contact Sensor Device Example
#
# - Presents as a Contact Sensor (endpoint 1)
# - Samples a simulated contact every 10 seconds
module MatterContactSensor
  class Device < Matter::Device
    include Examples::Console

    SAMPLE_INTERVAL = 10.seconds

    # How often a sample finds the contact open.
    OPEN_CHANCE_PERCENT = 25

    identity vendor: "Spider-Gazelle", product: "Crystal Contact Sensor",
      vendor_id: Matter::SetupPayload.test_vendor_id,
      product_id: rand(0x0001_u16..0xFFFF_u16),
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::CONTACT_SENSOR

    storage yaml: "matter_contact_sensor_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::CONTACT_SENSOR do
      cluster Matter::Cluster::BooleanState, state_value: false, as: :contact
      cluster Matter::Cluster::Identify, identify_type: :visible_led
      cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Example Contact")]
    end

    on(:contact, :state_changed) do |_old_value, new_value|
      notify "Contact: #{new_value ? "OPEN" : "CLOSED"}"
    end

    def console_notes : Array(String)
      ["Device Type: Contact Sensor"]
    end

    def state_details : Nil
      puts "  Contact: #{contact_state}"
      puts "  Sample interval: #{SAMPLE_INTERVAL.total_seconds.to_i}s"
    end

    def status_details : Nil
      puts "  Contact: #{contact_state}"
    end

    def commands : Array(Tuple(String, String))
      [{"sample", "Sample the contact now"}]
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

    # true = contact open, false = contact closed
    private def sample : Nil
      contact.update_state(rand(0..99) < OPEN_CHANCE_PERCENT)
    end

    private def contact_state : String
      contact.state_value? ? "OPEN" : "CLOSED"
    end
  end
end

Examples.main("Matter Contact Sensor Device") { MatterContactSensor::Device.new }
