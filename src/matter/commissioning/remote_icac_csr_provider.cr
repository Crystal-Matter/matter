require "json"
require "base64"
require "../error"
require "../fabric"

module Matter
  module Commissioning
    # Test-only, single-use local mailbox for an SDK JFC-owned Anchor ICAC.
    # The service validates the CSR signature and authenticated public key.
    class RemoteIcacCsrProvider
      MAX_CSR_BYTES = 1024

      def initialize(@path : String, @fabric_id : UInt64, @root_public_key : Bytes,
                     @timeout : Time::Span = 5.seconds)
        raise Matter::ConfigurationError.new("Invalid remote CSR fabric") if @fabric_id == Fabric::RESERVED_FABRIC_ID
        unless @root_public_key.size == 65 && @root_public_key[0] == 4
          raise Matter::ConfigurationError.new("Invalid remote CSR root public key")
        end
      end

      def request : Bytes
        raise Matter::CommissioningError.new("Remote CSR mailbox is busy") if File.exists?(@path)
        nonce = Random::Secure.hex(16)
        temporary = "#{@path}.#{nonce}.tmp"
        request = {
          "operation"       => "icac-csr",
          "nonce"           => nonce,
          "fabric_id"       => @fabric_id,
          "root_public_key" => @root_public_key.hexstring,
        }
        File.write(temporary, request.to_json)
        File.rename(temporary, @path)
        deadline = Time.instant + @timeout
        while Time.instant < deadline
          value = JSON.parse(File.read(@path)).as_h?
          if value && value["nonce"]?.try(&.as_s?) == nonce
            status = value["status"]?.try(&.as_s?)
            if status == "ok"
              encoded = value["csr"]?.try(&.as_s?) || raise Matter::CommissioningError.new("Remote CSR missing")
              csr = Base64.decode(encoded)
              unless 0 < csr.size <= MAX_CSR_BYTES
                raise Matter::CommissioningError.new("Remote CSR size invalid")
              end
              return csr
            elsif status
              raise Matter::CommissioningError.new("Remote CSR unavailable: #{status}")
            end
          end
          sleep 25.milliseconds
        end
        raise Matter::TimeoutError.new("Remote ICAC CSR timed out")
      rescue ex : JSON::ParseException | File::Error | Base64::Error
        raise Matter::CommissioningError.new("Invalid remote CSR mailbox", cause: ex)
      ensure
        File.delete(temporary) if temporary && File.exists?(temporary)
      end
    end
  end
end
