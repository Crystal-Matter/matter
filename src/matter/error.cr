require "./interaction_model/status_code"

module Matter
  # Base class for every error the library raises on its own behalf.
  #
  # `ArgumentError` is still used for programmer and configuration mistakes
  # (constructor validation, feature conformance, DTO field lengths) and
  # `KeyError` for endpoint / cluster lookup misses. Everything else that can
  # fail at runtime derives from `Matter::Error` so callers can rescue the
  # whole family, or a specific branch, without catching unrelated bugs.
  class Error < Exception
    def initialize(message : String? = nil, cause : Exception? = nil)
      super(message, cause)
    end
  end

  # TLV / DER / message-header / setup-payload parsing failures and short slices.
  class CodecError < Error
  end

  # Missing or unparseable key material, EC primitive failures.
  class CryptoError < Error
  end

  # A MIC, signature or PAKE confirmation failed to verify.
  class AuthenticationError < CryptoError
  end

  # NOC / RCAC / DAC parsing, chain validation and certificate construction.
  class CertificateError < Error
  end

  # Storage backend I/O, empty context or key, corrupt blob.
  class StorageError < Error
  end

  # Persisted Access Control state cannot be restored safely. Device startup
  # must stop rather than silently boot without its ACL or managed ARL.
  class AccessControlRestoreError < StorageError
  end

  # Message counter overflow, replay detection, decryption failure.
  class SessionError < Error
  end

  # PASE / CASE / Interaction Model state-machine violations and malformed
  # peer responses.
  class ProtocolError < Error
  end

  # A controller exchange did not receive its response in time.
  class TimeoutError < ProtocolError
  end

  # Failsafe, commissioning window and fabric violations, or a remote
  # commissioning command that was rejected.
  class CommissioningError < Error
  end

  # Socket creation / bind / multicast join and discovery failures.
  class TransportError < Error
  end

  # A node was assembled in a way the data model does not allow: a cluster
  # added to the wrong endpoint, or an endpoint that does not carry every
  # server cluster its device type makes mandatory. Raised while the device is
  # being built (at boot, or when a bridge adds an endpoint), never in response
  # to a message from the wire.
  class ConfigurationError < Error
  end

  # A cluster handler failure that maps directly onto an Interaction Model
  # status. Raised inside cluster code and converted to a status at the
  # cluster boundary (`Cluster#invoke_command` / `Cluster#write_attribute`).
  class ClusterError < Error
    getter status : InteractionModel::StatusCode
    getter cluster_status : UInt8?

    def initialize(
      message : String? = nil,
      @status : InteractionModel::StatusCode = InteractionModel::StatusCode::Failure,
      @cluster_status : UInt8? = nil,
      cause : Exception? = nil,
    )
      super(message, cause)
    end

    # Build from a status received on the wire (a `StatusIB`); an unknown
    # status byte is reported as the generic `Failure`.
    def self.from_wire(message : String, status : UInt8, cluster_status : UInt8? = nil) : ClusterError
      new(message, InteractionModel::StatusCode.from_value?(status) || InteractionModel::StatusCode::Failure, cluster_status)
    end

    def to_status : InteractionModel::Status
      InteractionModel::Status.new(@status, @cluster_status)
    end
  end
end
