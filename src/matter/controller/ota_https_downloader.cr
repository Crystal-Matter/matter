require "http/client"
require "uri"
require "../error"

module Matter
  module Controller
    # Streams an OTA image from an HTTPS origin into application-owned storage.
    # The default HTTP client verifies the server certificate. Redirects and
    # encoded bodies are rejected so the validated bytes are exactly those
    # received from the selected origin.
    class OtaHttpsDownloader
      CONNECT_TIMEOUT = 10.seconds
      READ_TIMEOUT    = 30.seconds
      BUFFER_SIZE     = 8192
      MAX_URI_SIZE    =  256

      alias ClientFactory = Proc(URI, HTTP::Client)

      def initialize(@client_factory : ClientFactory = ->(uri : URI) { HTTP::Client.new(uri) })
      end

      def download(url : String, sink : IO, max_bytes : UInt64) : UInt64
        unless url.bytesize <= MAX_URI_SIZE
          raise Matter::ProtocolError.new("OTA HTTPS URI is too long")
        end
        uri = URI.parse(url)
        unless uri.scheme == "https" && uri.host && uri.user.nil? && uri.password.nil?
          raise Matter::ProtocolError.new("OTA image URI must use an HTTPS origin")
        end

        client = @client_factory.call(uri)
        begin
          client.connect_timeout = CONNECT_TIMEOUT
          client.read_timeout = READ_TIMEOUT
          client.compress = false
          bytes_downloaded = 0_u64
          client.exec("GET", uri.request_target) do |response|
            unless response.status_code == 200
              reject_response(client, "OTA HTTPS image response was not 200")
            end
            if encoding = response.headers["Content-Encoding"]?
              unless encoding.downcase == "identity"
                reject_response(client, "OTA HTTPS image used content encoding")
              end
            end
            if length = response.headers["Content-Length"]?
              declared = length.to_u64?
              unless declared && declared <= max_bytes
                reject_response(client, "OTA HTTPS image exceeds the size limit")
              end
            end

            buffer = Bytes.new(BUFFER_SIZE)
            while (read = response.body_io.read(buffer)) > 0
              if read.to_u64 > max_bytes - bytes_downloaded
                reject_response(client, "OTA HTTPS image exceeds the size limit")
              end
              sink.write(buffer[0, read])
              bytes_downloaded += read.to_u64
            end
          end
          bytes_downloaded
        ensure
          client.close
        end
      rescue ex : URI::Error
        raise Matter::ProtocolError.new("Invalid OTA HTTPS URI", cause: ex)
      end

      # Crystal's HTTP::Client can retry a keep-alive request when a block
      # raises. Close first so a rejected offer cannot trigger a second GET.
      private def reject_response(client : HTTP::Client, message : String) : NoReturn
        client.close
        raise Matter::ProtocolError.new(message)
      end
    end
  end
end
