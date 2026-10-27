require "./support/console"
require "./support/main"

# A synthetic Casting Video Client receiving application-defined messages.
# Production hosts validate the sender and interpret Data in this callback.
module MatterContentAppObserver
  alias Observer = Matter::Cluster::ContentAppObserver

  class Device < Matter::Device
    include Examples::Console

    identity vendor: "Spider-Gazelle", product: "Synthetic Content App Observer",
      vendor_id: Matter::Fabric::DEFAULT_VENDOR_ID,
      product_id: 0x0510_u16,
      discriminator: Matter::SetupPayload.generate_random_discriminator,
      pin: Matter::SetupPayload.generate_random_pin,
      device_type: Matter::DeviceType::ROOT_NODE

    storage yaml: "matter_content_app_observer_storage.yml"

    endpoint 1, device_type: Matter::DeviceType::CASTING_VIDEO_CLIENT do
      cluster Observer, as: :observer
    end

    protected def before_start : Nil
      observer.on_content_app_message do |request, fabric, node|
        puts "Content App message from fabric #{fabric}, node #{node}: #{request.data}"
        if request.data == "ping" && request.encoding_hint == "text/plain"
          Observer::ContentAppMessageResponse.new(Observer::Status::Success, "pong", "text/plain")
        else
          Observer::ContentAppMessageResponse.new(Observer::Status::UnexpectedData)
        end
      end
      super
    end
  end
end

Examples.main("Synthetic Content App Observer") { MatterContentAppObserver::Device.new }
