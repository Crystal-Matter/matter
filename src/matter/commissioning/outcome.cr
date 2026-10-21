module Matter
  module Commissioning
    # CommissioningErrorEnum: the result every General Commissioning command
    # answers with.
    #
    # Matter Core Spec §11.10.5.1
    enum ErrorCode : UInt8
      OK                            = 0 # Success
      ValueOutsideRange             = 1 # Value outside allowed range
      InvalidAuthentication         = 2 # Invalid authentication
      NoFailSafe                    = 3 # Fail-safe not armed
      BusyWithOtherAdmin            = 4 # Busy with another administrator
      RequiredTCNotAccepted         = 5 # Terms & Conditions not accepted
      TCAcknowledgementsNotReceived = 6 # No Terms & Conditions acknowledgements received
      TCMinVersionNotMet            = 7 # Terms & Conditions minimum version not met
    end

    # What a commissioning service decided about a request. The cluster that
    # received the request encodes it into that command's response struct.
    struct Outcome
      getter error : ErrorCode
      getter debug_text : String

      def initialize(@error : ErrorCode = ErrorCode::OK, @debug_text : String = "")
      end

      def ok? : Bool
        @error.ok?
      end
    end
  end
end
