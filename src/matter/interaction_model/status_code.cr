module Matter
  module InteractionModel
    # Interaction Model status codes from Matter spec
    enum StatusCode : UInt8
      # Success
      Success = 0x00

      # General errors
      Failure               = 0x01
      InvalidSubscription   = 0x7D
      UnsupportedAccess     = 0x7E
      UnsupportedEndpoint   = 0x7F
      InvalidAction         = 0x80
      UnsupportedCommand    = 0x81
      Deprecated82          = 0x82
      Deprecated83          = 0x83
      Deprecated84          = 0x84
      InvalidCommand        = 0x85
      UnsupportedAttribute  = 0x86
      ConstraintError       = 0x87
      UnsupportedWrite      = 0x88
      ResourceExhausted     = 0x89
      Deprecated8A          = 0x8A
      NotFound              = 0x8B
      UnreportableAttribute = 0x8C
      InvalidDataType       = 0x8D
      Deprecated8E          = 0x8E
      UnsupportedRead       = 0x8F
      Deprecated90          = 0x90
      Deprecated91          = 0x91
      DataVersionMismatch   = 0x92
      Deprecated93          = 0x93
      Timeout               = 0x94
      Reserved95            = 0x95
      Reserved96            = 0x96
      Reserved97            = 0x97
      Reserved98            = 0x98
      Reserved99            = 0x99
      Reserved9A            = 0x9A
      Reserved9B            = 0x9B
      Busy                  = 0x9C
      AccessRestricted      = 0x9D
      Deprecated9E          = 0x9E
      Deprecated9F          = 0x9F
      DeprecatedA0          = 0xA0
      DeprecatedA1          = 0xA1
      DeprecatedA2          = 0xA2
      DeprecatedA3          = 0xA3
      DeprecatedA4          = 0xA4
      DeprecatedA5          = 0xA5
      DeprecatedA6          = 0xA6
      DeprecatedA7          = 0xA7
      DeprecatedA8          = 0xA8

      # Request is for a cluster that doesn't exist on the endpoint (a general
      # status code that happens to sit inside the 0xC0-0xFF range)
      UnsupportedCluster = 0xC3

      # A command or writable attribute requires a TimedRequest on this exchange.
      NeedsTimedInteraction = 0xC6

      # Request is for an event the cluster instance does not support
      # (Matter Core 8.10.1, another general code inside the 0xC0-0xFF range)
      UnsupportedEvent       = 0xC7
      TimedRequestMismatch   = 0xC9
      FailsafeRequired       = 0xCA
      InvalidInState         = 0xCB
      DynamicConstraintError = 0xCF
      AlreadyExists          = 0xD0

      # Other values in 0xC0-0xFF may be cluster-specific. The named general
      # statuses above keep their assigned meanings in that range.

      def success?
        self == Success
      end

      # Human readable label. `Enum#to_s` and `Enum#to_s(io)` are independent in
      # the stdlib (single-value interpolation calls the former, `IO#<<` and
      # `Log` the latter), so both are overridden to share this label.
      def label : String
        case self
        when Success                then "Success"
        when Failure                then "Failure"
        when InvalidSubscription    then "Invalid Subscription"
        when UnsupportedAccess      then "Unsupported Access"
        when UnsupportedEndpoint    then "Unsupported Endpoint"
        when InvalidAction          then "Invalid Action"
        when UnsupportedCommand     then "Unsupported Command"
        when InvalidCommand         then "Invalid Command"
        when UnsupportedAttribute   then "Unsupported Attribute"
        when ConstraintError        then "Constraint Error"
        when UnsupportedWrite       then "Unsupported Write"
        when ResourceExhausted      then "Resource Exhausted"
        when NotFound               then "Not Found"
        when UnreportableAttribute  then "Unreportable Attribute"
        when InvalidDataType        then "Invalid Data Type"
        when UnsupportedRead        then "Unsupported Read"
        when DataVersionMismatch    then "Data Version Mismatch"
        when Timeout                then "Timeout"
        when Busy                   then "Busy"
        when AccessRestricted       then "Access Restricted"
        when UnsupportedCluster     then "Unsupported Cluster"
        when NeedsTimedInteraction  then "Needs Timed Interaction"
        when UnsupportedEvent       then "Unsupported Event"
        when TimedRequestMismatch   then "Timed Request Mismatch"
        when FailsafeRequired       then "Failsafe Required"
        when InvalidInState         then "Invalid In State"
        when DynamicConstraintError then "Dynamic Constraint Error"
        when AlreadyExists          then "Already Exists"
        else                             "Unknown Status (#{Hex.u8(value)})"
        end
      end

      def to_s : String
        label
      end

      def to_s(io : IO) : Nil
        io << label
      end
    end

    # Status response with optional cluster-specific status
    struct Status
      property status : StatusCode
      property cluster_status : UInt8?

      def initialize(@status : StatusCode, @cluster_status : UInt8? = nil)
      end

      # One factory per usable status code: `Status.success`,
      # `Status.unsupported_attribute`, `Status.invalid_data_type`, ...
      # Deprecated and reserved members are excluded.
      {% for member in StatusCode.constants %}
        {% unless member.stringify.starts_with?("Deprecated") || member.stringify.starts_with?("Reserved") %}
          def self.{{ member.underscore }} : Status
            new(StatusCode::{{ member }})
          end
        {% end %}
      {% end %}

      # `Failure` carrying a cluster-specific status code
      def self.cluster_failure(code : UInt8) : Status
        new(StatusCode::Failure, code)
      end

      # :ditto:
      def self.cluster_failure(code : Enum) : Status
        new(StatusCode::Failure, code.value.to_u8)
      end

      def success?
        @status.success?
      end

      def to_s(io : IO) : Nil
        io << @status
        if cluster_status = @cluster_status
          io << " (cluster: " << Hex.u8(cluster_status) << ")"
        end
      end
    end
  end
end
