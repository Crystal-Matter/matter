require "../spec_helper"
require "../../src/matter/controller/ota_https_downloader"

private class OtaHttpFixtureIO < IO
  getter written = IO::Memory.new

  def initialize(response : Bytes)
    @response = IO::Memory.new(response)
  end

  def read(slice : Bytes) : Int32
    @response.read(slice)
  end

  def write(slice : Bytes) : Nil
    @written.write(slice)
  end
end

private def ota_http_response(status : String, body : Bytes,
                              declared_size : Int32 = body.size) : Bytes
  headers = "HTTP/1.1 #{status}\r\nContent-Length: #{declared_size}\r\nConnection: close\r\n\r\n"
  headers.to_slice + body
end

describe Matter::Controller::OtaHttpsDownloader do
  it "streams an HTTPS response into caller-owned IO within the configured bound" do
    payload = Bytes.new(4097) { |index| (index % 251).to_u8 }
    fixture = OtaHttpFixtureIO.new(ota_http_response("200 OK", payload))
    factory = ->(_uri : URI) { HTTP::Client.new(fixture, "updates.example.test", 443) }
    downloader = Matter::Controller::OtaHttpsDownloader.new(client_factory: factory)
    sink = IO::Memory.new

    downloader.download("https://updates.example.test/firmware.ota", sink,
      max_bytes: 8192_u64).should eq(payload.size.to_u64)
    sink.to_slice.should eq(payload)
    fixture.written.to_s.should contain("GET /firmware.ota HTTP/1.1")
  end

  it "rejects HTTP, redirects, and responses exceeding the image cap" do
    downloader = Matter::Controller::OtaHttpsDownloader.new
    expect_raises(Matter::ProtocolError) do
      downloader.download("http://updates.example.test/image", IO::Memory.new,
        max_bytes: 1024_u64)
    end

    redirect = OtaHttpFixtureIO.new(ota_http_response("302 Found", Bytes.empty))
    redirect_downloader = Matter::Controller::OtaHttpsDownloader.new(
      client_factory: ->(_uri : URI) { HTTP::Client.new(redirect, "updates.example.test", 443) })
    expect_raises(Matter::ProtocolError) do
      redirect_downloader.download("https://updates.example.test/image", IO::Memory.new,
        max_bytes: 1024_u64)
    end

    oversized = OtaHttpFixtureIO.new(ota_http_response("200 OK", Bytes.new(1025), 1025))
    oversized_downloader = Matter::Controller::OtaHttpsDownloader.new(
      client_factory: ->(_uri : URI) { HTTP::Client.new(oversized, "updates.example.test", 443) })
    expect_raises(Matter::ProtocolError) do
      oversized_downloader.download("https://updates.example.test/image", IO::Memory.new,
        max_bytes: 1024_u64)
    end

    # Chunked bodies have no trusted Content-Length, so enforce the cap while
    # streaming as well as when parsing response headers.
    chunked_body = "#{1025.to_s(16)}\r\n#{"a" * 1025}\r\n0\r\n\r\n"
    chunked = OtaHttpFixtureIO.new(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n#{chunked_body}".to_slice)
    chunked_downloader = Matter::Controller::OtaHttpsDownloader.new(
      client_factory: ->(_uri : URI) { HTTP::Client.new(chunked, "updates.example.test", 443) })
    expect_raises(Matter::ProtocolError) do
      chunked_downloader.download("https://updates.example.test/image", IO::Memory.new,
        max_bytes: 1024_u64)
    end

    encoded = OtaHttpFixtureIO.new(
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Encoding: br\r\n\r\nabc".to_slice)
    encoded_downloader = Matter::Controller::OtaHttpsDownloader.new(
      client_factory: ->(_uri : URI) { HTTP::Client.new(encoded, "updates.example.test", 443) })
    expect_raises(Matter::ProtocolError) do
      encoded_downloader.download("https://updates.example.test/image", IO::Memory.new,
        max_bytes: 1024_u64)
    end
  end
end
