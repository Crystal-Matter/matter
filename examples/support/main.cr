require "../../src/matter"

module Examples
  # ProductId zero is reserved; synthetic devices choose a nonzero example ID.
  RANDOM_PRODUCT_ID_RANGE = 1_u16..UInt16::MAX

  # Log level when `MATTER_LOG` names none.
  DEFAULT_LOG_LEVEL = "info"

  # The `__main__` of every example: sets logging up from `MATTER_LOG`, builds
  # the device, shuts it down cleanly on SIGINT/SIGTERM (so storage is
  # flushed and the device comes back commissioned) and blocks until it stops.
  #
  # ```
  # Examples.main("Matter Switch Device") { MatterSwitch::Device.new }
  # ```
  def self.main(title : String, & : -> Matter::Device) : Nil
    puts "Starting #{title}..."
    puts ""

    ::Log.setup(::Log::Severity.parse(ENV["MATTER_LOG"]? || DEFAULT_LOG_LEVEL))

    device = yield

    Process.on_terminate do
      puts ""
      puts ""
      puts "Received interrupt signal"
      device.shutdown!
    end

    device.start
    device.await_shutdown
  end
end
