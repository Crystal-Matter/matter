require "goban"
require "../../src/matter"

# Shared console front-end for the example devices.
module Examples
  # The parts of an example device that are the same for every example: the
  # start-up banners, the commissioning QR code and pairing line, the
  # interactive command loop and the factory reset.
  #
  # Include it in a `Matter::Device` subclass and override the hooks it leaves
  # open:
  #
  # * `console_title` / `console_notes` - the start-up header
  # * `state_details` / `status_details` - the device-specific lines of the
  #   start-up state dump and of `status`
  # * `commands` - the device's own commands, for `help`
  # * `handle_command` - runs one of them; returns false when the name is not
  #   one of the device's own
  #
  # The lifecycle hooks (`before_start`, `started_commissioning_mode`,
  # `started_operational_mode`, `on_started`, `on_shutdown`) are implemented
  # here; an example that needs more calls `super`.
  #
  # Two lines of the output are a contract with the end-to-end tests and
  # `examples/run_validation.sh`, which scrape them from the device's log:
  # `chip-tool pairing code 1 <code>` (printed only while un-commissioned) and
  # the "... Commissioning Mode" / "... Operational Mode" banner, whose last
  # occurrence tells the tests which mode the device is in.
  module Console
    PROMPT               = "> "
    NON_INTERACTIVE_FLAG = "--no-interactive"
    RULE                 = "=" * 70
    CONFIRMATION         = "yes"

    # How often `every` looks at the shutdown flag while waiting.
    TICK = 1.second

    # Set while the device is running; `every` stops with it.
    @sampling : Bool = false

    # Offered by every example, on top of its own `commands`.
    COMMON_COMMANDS = [
      {"status", "Show detailed device status"},
      {"reset", "Reset device to factory defaults"},
      {"quit", "Shut down the device and exit"},
    ]

    # ------------------------------------------------------------------------
    # Hooks
    # ------------------------------------------------------------------------

    # The title of the start-up header.
    def console_title : String
      device_name
    end

    # Lines printed under the title, e.g. the endpoint layout.
    def console_notes : Array(String)
      [] of String
    end

    # Device-specific lines of the start-up state dump.
    def state_details : Nil
    end

    # Device-specific lines of `status`.
    def status_details : Nil
    end

    # The device's own commands, as `{name, description}`.
    def commands : Array(Tuple(String, String))
      [] of Tuple(String, String)
    end

    # Runs the device's own command *name*; false when it has no such command.
    def handle_command(name : String, argument : String?) : Bool
      false
    end

    # ------------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------------

    protected def before_start : Nil
      print_header
      print_state
    end

    protected def started_commissioning_mode : Nil
      puts "Starting in Commissioning Mode"
      puts "The device is ready to be paired with a Matter controller."
      puts ""
      puts "mDNS Advertisement Active:"
      puts "  Service: #{Matter::MDNS::ServiceNames::COMMISSIONING}"
      puts "  Instance: #{responder.commissioning_instance_name || "<pending>"}"
      puts "  Hostname: #{hostname}"
      puts "  Port: #{port}"
      puts "  Discriminator: #{discriminator}"
      puts ""

      print_qr_code

      puts "To pair this device:"
      puts "  chip-tool pairing code 1 #{setup_code}"
      puts ""
    end

    protected def started_operational_mode : Nil
      puts "Starting in Operational Mode"
      puts "The device is commissioned and ready for use."
      puts ""

      fabric_table.all_fabrics.each do |fabric|
        puts "Operational Advertisement (Fabric #{fabric.fabric_index}):"
        puts "  Service: #{Matter::MDNS::ServiceNames::OPERATIONAL}"
        puts "  Fabric ID: 0x#{fabric.fabric_id.to_s(16).upcase}"
        puts "  Node ID: 0x#{fabric.node_id.to_s(16).upcase}"
        puts ""
      end
    end

    protected def on_started : Nil
      @sampling = true
      start_console
    end

    protected def on_shutdown : Nil
      @sampling = false
      puts "Shutdown complete"
    end

    # Runs *block* every *interval* in its own fiber until the device shuts
    # down, for the examples that simulate a sensor.
    def every(interval : Time::Span, &block : -> Nil) : Nil
      spawn do
        while @sampling
          interval.total_seconds.to_i.times do
            break unless @sampling
            sleep TICK
          end
          block.call if @sampling
        end
      end
    end

    # ------------------------------------------------------------------------
    # Console
    # ------------------------------------------------------------------------

    # Whether the device was started without `--no-interactive`.
    def interactive? : Bool
      !ARGV.includes?(NON_INTERACTIVE_FLAG)
    end

    # Runs the command loop in its own fiber, or explains that there is none.
    def start_console : Nil
      unless interactive?
        puts "Running in non-interactive mode (#{NON_INTERACTIVE_FLAG})"
        puts "Press Ctrl+C to stop."
        puts ""
        return
      end

      spawn { run_console }
    end

    # Prints *lines* above a fresh prompt, for output that arrives while the
    # user is typing.
    def notify(*lines : String) : Nil
      puts ""
      lines.each { |line| puts line }
      reprompt
    end

    def reprompt : Nil
      print PROMPT if interactive?
    end

    # Runs the device's command *input*; `status`, `reset`, `help` and `quit`
    # before the device's own commands.
    def dispatch(input : String) : Nil
      name, _, argument = input.strip.partition(' ')
      return if name.empty?
      argument = argument.strip
      argument = nil if argument.empty?

      case name.downcase
      when "status"
        show_status
      when "reset"
        factory_reset
      when "help", "?"
        show_help
      when "quit", "exit", "q"
        puts "Shutting down..."
        shutdown!
      else
        return if handle_command(name.downcase, argument)
        puts "Unknown command: #{name}"
        puts "Type 'help' for available commands"
      end
    end

    def show_status : Nil
      puts ""
      puts "Device Status:"
      puts "  Name: #{device_name}"
      status_details
      puts "  Commissioned: #{fabric_table.empty? ? "No" : "Yes"}"
      puts "  Fabrics: #{fabric_table.size}"
      puts "  Sessions: #{message_handler.sessions.size}"
      puts "  Subscriptions: #{message_handler.active_subscriptions.size}"
      puts ""
    end

    def show_help : Nil
      puts ""
      puts "Available Commands:"
      print_commands
      puts ""
    end

    # Drops every fabric and every stored document, then exits: the device
    # comes back un-commissioned on the next start.
    def factory_reset : Nil
      print "Are you sure you want to reset to factory defaults? (#{CONFIRMATION}/no): "
      confirmation = gets
      return unless confirmation && confirmation.strip.downcase == CONFIRMATION

      begin
        before_factory_reset
      rescue ex : Matter::Error
        puts "Factory reset stopped: #{ex.message}"
        return
      end
      puts "Performing factory reset..."
      shutdown!
      persistence.reset!
      puts "Factory reset complete."
      puts "Please restart the application."
      exit(0)
    end

    protected def before_factory_reset : Nil
    end

    # ------------------------------------------------------------------------
    # Setup payload
    # ------------------------------------------------------------------------

    # The manual pairing code, e.g. "3497-011-2332".
    def setup_code : String
      Matter::SetupPayload.generate_manual_code(discriminator, setup_pin)
    end

    def qr_code_payload : String
      Matter::SetupPayload::QRCode.generate_qr_code(
        discriminator: discriminator,
        pin: setup_pin,
        vendor_id: vendor_id,
        product_id: product_id,
        flow: Matter::SetupPayload::QRCode::CommissionFlow::Standard,
        capabilities: Matter::SetupPayload::QRCode::DiscoveryCapability::BLE
      )
    end

    def print_qr_code : Nil
      qr = Goban::QR.encode_string(qr_code_payload, Goban::ECC::Level::Low)
      puts "Scan this QR code with your Matter controller app:"
      puts ""
      qr.print_to_console
      puts ""
    rescue error
      puts "Failed to generate QR code: #{error.message}"
    end

    # ------------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------------

    private def run_console : Nil
      puts "Interactive Commands:"
      print_commands
      puts ""

      loop do
        print PROMPT
        input = gets
        break unless input
        dispatch(input)
      end
    end

    private def print_commands : Nil
      table = commands + COMMON_COMMANDS
      width = table.max_of { |(name, _)| name.size }
      table.each { |(name, description)| puts "  #{name.ljust(width)} - #{description}" }
    end

    private def print_header : Nil
      puts ""
      puts RULE
      puts "  #{console_title}"
      console_notes.each { |note| puts "  #{note}" }
      puts RULE
      puts ""
    end

    private def print_state : Nil
      puts "Loading device state..."
      puts "  Name: #{device_name}"
      state_details
      puts "  Commissioned: #{fabric_table.empty? ? "No" : "Yes"}"
      puts "  Fabrics: #{fabric_table.size}"
      puts "  Discriminator: #{discriminator}"
      puts "  Setup PIN: #{setup_pin}"
      puts ""
      ip_addresses.each do |ip|
        puts "  IP: #{ip.address} (#{ip.family == Socket::Family::INET ? "IPv4" : "IPv6"})"
      end
      puts ""
    end
  end
end
