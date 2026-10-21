require "../spec_helper"
require "../../src/matter/controller"

describe Matter::Controller::Commissioning::Commissioner do
  it "rejects commissioning before PASE and AddTrustedRoot when no verifier is configured" do
    require_udp_sockets!
    store = Matter::Controller::StateStore.new(Matter::Storage::Memory.new)
    commissioner = Matter::Controller::Commissioning::Commissioner.new(store)
    manual_code = Matter::SetupPayload.generate_manual_code(0x0F00_u16, 20202021_u32)

    expect_raises(Matter::ConfigurationError, /attestation/) do
      commissioner.pairing_code(0x1234_u64, manual_code,
        Socket::IPAddress.new("127.0.0.1", 5540))
    end
    store.load.fabrics.should be_empty
    store.load.nodes.should be_empty
  ensure
    commissioner.try(&.close)
  end
end
