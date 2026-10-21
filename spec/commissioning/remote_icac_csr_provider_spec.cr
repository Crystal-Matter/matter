require "../spec_helper"
require "../../src/matter/commissioning/remote_icac_csr_provider"
require "../../src/matter/crypto/pkcs10"

describe Matter::Commissioning::RemoteIcacCsrProvider do
  it "requests one nonce-bound CSR from the SDK bridge mailbox" do
    path = File.join(Dir.tempdir, "matter-remote-csr-#{Random::Secure.hex(8)}.json")
    root_public_key = Bytes[4_u8] + Bytes.new(64, 1_u8)
    crypto = Matter::Crypto::StandardCrypto.new
    icac_key = crypto.create_key_pair
    csr = Matter::Crypto::Pkcs10.create(icac_key, crypto)
    provider = Matter::Commissioning::RemoteIcacCsrProvider.new(path, 0x1234_u64, root_public_key)
    spawn do
      until File.exists?(path)
        sleep 5.milliseconds
      end
      request = JSON.parse(File.read(path))
      request["fabric_id"].as_i.should eq(0x1234)
      request["root_public_key"].as_s.should eq(root_public_key.hexstring)
      File.write(path, {"nonce" => request["nonce"].as_s, "status" => "ok",
                        "csr" => Base64.strict_encode(csr)}.to_json)
    end
    result = provider.request
    Matter::Crypto::Pkcs10.verify(result, icac_key.public_key, crypto)
    expect_raises(Matter::CommissioningError, /busy/) { provider.request }
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "fails when no JFC stream provides a result" do
    path = File.join(Dir.tempdir, "matter-remote-csr-#{Random::Secure.hex(8)}.json")
    provider = Matter::Commissioning::RemoteIcacCsrProvider.new(path, 1_u64,
      Bytes[4_u8] + Bytes.new(64, 1_u8), 20.milliseconds)
    expect_raises(Matter::TimeoutError) { provider.request }
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
