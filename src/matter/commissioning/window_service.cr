require "log"
require "../error"
require "../mdns"
require "../setup_payload"

module Matter
  module Commissioning
    # State of the commissioning window, as reported by the
    # AdministratorCommissioning WindowStatus attribute (Matter Core §11.19.7.1)
    enum WindowStatus : UInt8
      WindowNotOpen      = 0 # No commissioning window open
      EnhancedWindowOpen = 1 # Enhanced commissioning window open (PAKE)
      BasicWindowOpen    = 2 # Basic commissioning window open
    end

    # Cluster-specific status codes of the AdministratorCommissioning cluster
    enum WindowStatusCode : UInt8
      Busy               = 2 # Commissioning window already open
      PAKEParameterError = 3 # Invalid PAKE parameters
      WindowNotOpen      = 4 # No window open for revocation
    end

    # A window is already open: answered with the IM `Busy` status.
    class BusyError < Matter::ClusterError
      def initialize(message : String? = nil, cause : Exception? = nil)
        super(message, InteractionModel::StatusCode::Busy, nil, cause)
      end
    end

    # PAKE parameters failed validation: `Failure` with the cluster-specific
    # `PAKEParameterError` status code.
    class PAKEParameterError < Matter::ClusterError
      def initialize(message : String? = nil, cause : Exception? = nil)
        super(message, InteractionModel::StatusCode::Failure, WindowStatusCode::PAKEParameterError.value, cause)
      end
    end

    # No window to revoke: `Failure` with the cluster-specific
    # `WindowNotOpen` status code.
    class WindowNotOpenError < Matter::ClusterError
      def initialize(message : String? = nil, cause : Exception? = nil)
        super(message, InteractionModel::StatusCode::Failure, WindowStatusCode::WindowNotOpen.value, cause)
      end
    end

    # The attributes a commissioner reads the window state back from,
    # implemented by `Cluster::AdministratorCommissioning`.
    module WindowTarget
      # Publish the window state. `notify` bumps the cluster data version, which
      # a close does and an open (the commissioner already knows) does not.
      abstract def publish_window_state(
        status : WindowStatus,
        admin_fabric_index : UInt8?,
        admin_vendor_id : UInt16?,
        notify : Bool,
      ) : Nil
    end

    # The commissioning window behind `Cluster::AdministratorCommissioning`:
    # the window state, its timeout, and the PASE and mDNS side effects of
    # opening and closing it.
    #
    # The side effects are reached through the callbacks below, which the
    # device installs on the cluster; the service never touches the protocol
    # layer itself.
    #
    # Matter Core Spec §11.19 - Administrator Commissioning Cluster
    class WindowService
      Log = ::Log.for("matter.commissioning.window_service")

      # PAKE parameter bounds (Matter Core §3.10, §11.19.8.1)
      CRYPTO_GROUP_SIZE_BYTES       =      32 # w0 size
      CRYPTO_PUBLIC_KEY_SIZE_BYTES  =      65 # L size (point on curve)
      PAKE_PASSCODE_VERIFIER_LENGTH =      97 # w0 (32) + L (65)
      PBKDF2_MIN_ITERATIONS         =    1000
      PBKDF2_MAX_ITERATIONS         = 100_000
      PAKE_SALT_MIN_LENGTH          =      16
      PAKE_SALT_MAX_LENGTH          =      32

      # Commissioning timeout bounds in seconds (Matter Core §11.19.8.1.1)
      MINIMUM_COMMISSIONING_TIMEOUT  =   180_u16 # 3 minutes
      STANDARD_COMMISSIONING_TIMEOUT =   900_u16 # 15 minutes (default max)
      MAXIMUM_COMMISSIONING_TIMEOUT  = 65535_u16 # ~18 hours (UInt16 max, extended commissioning)

      # PBKDF parameters a basic window generates for the device's own passcode
      BASIC_WINDOW_ITERATIONS  = 1000_u32
      BASIC_WINDOW_SALT_LENGTH =       32

      # Current window state
      getter status : WindowStatus = WindowStatus::WindowNotOpen
      getter admin_fabric_index : UInt8?
      getter admin_vendor_id : UInt16?

      # Window timing
      getter started_at : Time?
      getter expires_at : Time?

      # PAKE parameters of an enhanced window
      getter pake_verifier : Bytes?
      getter discriminator : UInt16?
      getter iterations : UInt32?
      getter salt : Bytes?
      getter? joint_window : Bool = false

      # Accepted CommissioningTimeout range
      property minimum_timeout : UInt16
      property maximum_timeout : UInt16

      # PASE server integration, installed by the device on the cluster
      property on_configure_pase_server : Proc(Bytes, UInt32, Bytes, Nil)? # (verifier, iterations, salt)
      property on_configure_pase_pin : Proc(UInt32, UInt32, Bytes, Nil)?   # (pin, iterations, salt)
      property on_stop_pase_server : Proc(Nil)?

      # mDNS advertising integration, installed by the device on the cluster.
      # The discriminator is nil for a basic window: the device advertises its
      # own. An enhanced window carries the administrator-requested one.
      property on_start_commissioning_advertising : Proc(UInt16?, MDNS::CommissioningMode, Nil)?
      property on_stop_commissioning_advertising : Proc(Nil)?

      @timeout_fiber : Fiber?
      @timeout_channel : Channel(Nil)?

      def initialize(
        @target : WindowTarget,
        @minimum_timeout : UInt16 = MINIMUM_COMMISSIONING_TIMEOUT,
        @maximum_timeout : UInt16 = STANDARD_COMMISSIONING_TIMEOUT,
      )
      end

      # Whether a commissioning window is open
      def open? : Bool
        @status != WindowStatus::WindowNotOpen
      end

      def enhanced_open? : Bool
        @status == WindowStatus::EnhancedWindowOpen
      end

      def basic_open? : Bool
        @status == WindowStatus::BasicWindowOpen
      end

      # Whether the window's timeout has passed
      def expired? : Bool
        return false unless expiry = @expires_at
        Time.utc >= expiry
      end

      # Time left on an open window
      def time_remaining : Time::Span?
        return unless open?
        return unless expiry = @expires_at

        remaining = expiry - Time.utc
        remaining > Time::Span.zero ? remaining : Time::Span.zero
      end

      # Handle OpenCommissioningWindow (0x00)
      #
      # Opens an enhanced window with the administrator's pre-computed PAKE
      # verifier, derived from an ephemeral passcode only it knows.
      def open_enhanced(
        timeout_seconds : UInt16,
        verifier : Bytes,
        discriminator : UInt16,
        iterations : UInt32,
        salt : Bytes,
        admin_fabric_index : UInt8?,
        admin_vendor_id : UInt16?,
        joint : Bool = false,
      ) : Nil
        Log.info { "OpenCommissioningWindow: timeout=#{timeout_seconds}s, discriminator=#{discriminator}" }

        validate_pake_parameters(verifier, iterations, salt)
        validate_timeout(timeout_seconds)
        ensure_closed
        @joint_window = joint

        open_window(
          timeout_seconds: timeout_seconds,
          status: WindowStatus::EnhancedWindowOpen,
          admin_fabric_index: admin_fabric_index,
          admin_vendor_id: admin_vendor_id,
          discriminator: discriminator
        )

        @pake_verifier = verifier
        @iterations = iterations
        @salt = salt
        @discriminator = discriminator

        if callback = @on_configure_pase_server
          callback.call(verifier, iterations, salt)
          Log.debug { "Configured PASE server with custom verifier" }
        end

        Log.info { "Enhanced commissioning window opened for #{timeout_seconds}s" }
      end

      # Handle OpenBasicCommissioningWindow (0x01)
      #
      # Opens a basic window onto the device's own passcode, generating the
      # PBKDF parameters the commissioner will receive during PASE.
      def open_basic(
        timeout_seconds : UInt16,
        admin_fabric_index : UInt8?,
        admin_vendor_id : UInt16?,
      ) : Nil
        Log.info { "OpenBasicCommissioningWindow: timeout=#{timeout_seconds}s" }

        validate_timeout(timeout_seconds)
        ensure_closed

        # A basic window carries no discriminator: the device advertises its own.
        open_window(
          timeout_seconds: timeout_seconds,
          status: WindowStatus::BasicWindowOpen,
          admin_fabric_index: admin_fabric_index,
          admin_vendor_id: admin_vendor_id
        )

        if callback = @on_configure_pase_pin
          # The device substitutes its own passcode; the pin passed here is only
          # a placeholder for implementations that have none of their own.
          callback.call(
            SetupPayload.default_pin,
            BASIC_WINDOW_ITERATIONS,
            Random::Secure.random_bytes(BASIC_WINDOW_SALT_LENGTH)
          )
          Log.debug { "Configured PASE server with default PIN" }
        end

        Log.info { "Basic commissioning window opened for #{timeout_seconds}s" }
      end

      # Handle RevokeCommissioning (0x02): close an open window, or fail
      def revoke : Nil
        Log.info { "RevokeCommissioning" }

        unless open?
          raise WindowNotOpenError.new("No commissioning window is opened that could be revoked")
        end

        close

        Log.info { "Commissioning window revoked" }
      end

      # Record an open window without any of the side effects of opening one:
      # no PASE configuration, no advertising and no timeout fiber.
      def mark_open(
        status : WindowStatus,
        timeout_seconds : UInt16,
        admin_fabric_index : UInt8?,
        admin_vendor_id : UInt16?,
      ) : Nil
        @status = status
        @admin_fabric_index = admin_fabric_index
        @admin_vendor_id = admin_vendor_id
        @started_at = Time.utc
        @expires_at = Time.utc + timeout_seconds.seconds
        @target.publish_window_state(@status, @admin_fabric_index, @admin_vendor_id, notify: true)
      end

      # Close the window: stop advertising, stop the timer, drop the PAKE
      # parameters and stop the PASE server
      def close : Nil
        stop_advertising
        stop_timeout

        @status = WindowStatus::WindowNotOpen
        @admin_fabric_index = nil
        @admin_vendor_id = nil

        @started_at = nil
        @expires_at = nil

        @pake_verifier = nil
        @discriminator = nil
        @iterations = nil
        @salt = nil
        @joint_window = false

        if callback = @on_stop_pase_server
          callback.call
          Log.debug { "Stopped PASE server" }
        end

        @target.publish_window_state(@status, @admin_fabric_index, @admin_vendor_id, notify: true)

        Log.info { "Commissioning window closed" }
      end

      # Open the window and start advertising and counting down
      private def open_window(
        timeout_seconds : UInt16,
        status : WindowStatus,
        admin_fabric_index : UInt8?,
        admin_vendor_id : UInt16?,
        discriminator : UInt16? = nil,
      ) : Nil
        @status = status
        @admin_fabric_index = admin_fabric_index
        @admin_vendor_id = admin_vendor_id
        @target.publish_window_state(@status, @admin_fabric_index, @admin_vendor_id, notify: false)

        @started_at = Time.utc
        @expires_at = Time.utc + timeout_seconds.seconds

        start_advertising(discriminator)
        start_timeout(timeout_seconds)

        # Yield to give the timeout fiber a chance to start
        Fiber.yield

        Log.debug { "Commissioning window initialized: status=#{status}, admin_fabric=#{admin_fabric_index}" }
      end

      private def ensure_closed : Nil
        raise BusyError.new("A commissioning window is already opened") if open?
      end

      # Validate PAKE parameters per Matter spec
      private def validate_pake_parameters(verifier : Bytes, iterations : UInt32, salt : Bytes) : Nil
        unless verifier.size == PAKE_PASSCODE_VERIFIER_LENGTH
          raise PAKEParameterError.new(
            "PAKE passcode verifier length is invalid (expected #{PAKE_PASSCODE_VERIFIER_LENGTH}, got #{verifier.size})"
          )
        end

        unless iterations >= PBKDF2_MIN_ITERATIONS && iterations <= PBKDF2_MAX_ITERATIONS
          raise PAKEParameterError.new(
            "PAKE iterations invalid (must be #{PBKDF2_MIN_ITERATIONS}-#{PBKDF2_MAX_ITERATIONS}, got #{iterations})"
          )
        end

        unless salt.size >= PAKE_SALT_MIN_LENGTH && salt.size <= PAKE_SALT_MAX_LENGTH
          raise PAKEParameterError.new(
            "PAKE salt has invalid length (must be #{PAKE_SALT_MIN_LENGTH}-#{PAKE_SALT_MAX_LENGTH}, got #{salt.size})"
          )
        end
      end

      # Validate the requested CommissioningTimeout
      private def validate_timeout(timeout : UInt16) : Nil
        if timeout < @minimum_timeout
          raise ArgumentError.new(
            "Commissioning timeout must not be lower than #{@minimum_timeout} seconds"
          )
        end

        if timeout > @maximum_timeout
          raise ArgumentError.new(
            "Commissioning timeout must not exceed #{@maximum_timeout} seconds"
          )
        end
      end

      # Close the window when its timeout passes
      private def start_timeout(timeout_seconds : UInt16) : Nil
        channel = Channel(Nil).new
        @timeout_channel = channel

        @timeout_fiber = spawn(name: "Commissioning Timeout") do
          select
          when timeout(timeout_seconds.seconds)
            if open?
              Log.warn { "Commissioning window timeout after #{timeout_seconds}s" }
              close
              Fiber.yield # Allow other fibers to see the changes
            end
          when channel.receive
            Log.debug { "Commissioning timeout cancelled" }
          end
        end
      end

      private def stop_timeout : Nil
        if channel = @timeout_channel
          # The timeout fiber is already past its select block when it is the
          # one closing the window.
          if Fiber.current != @timeout_fiber
            begin
              channel.send(nil)
            rescue Channel::ClosedError
            end
          end
          @timeout_channel = nil
        end
        @timeout_fiber = nil
      end

      # Advertise the open window over DNS-SD. A nil discriminator (basic
      # window) lets the device advertise its own.
      private def start_advertising(discriminator : UInt16?) : Nil
        mode = case @status
               when WindowStatus::BasicWindowOpen
                 MDNS::CommissioningMode::Basic
               when WindowStatus::EnhancedWindowOpen
                 @joint_window ? MDNS::CommissioningMode::Joint : MDNS::CommissioningMode::Enhanced
               else
                 MDNS::CommissioningMode::Disabled
               end

        if callback = @on_start_commissioning_advertising
          callback.call(discriminator, mode)
          Log.info { "Requested commissioning mDNS advertising (discriminator=#{discriminator || "device"} mode=#{mode})" }
        end
      end

      private def stop_advertising : Nil
        if callback = @on_stop_commissioning_advertising
          callback.call
          Log.info { "Requested commissioning mDNS stop" }
        end
      end
    end
  end
end
