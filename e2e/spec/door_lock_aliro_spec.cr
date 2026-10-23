require "./e2e_helper"

# Test-only reader delegate. chip-tool drives the actual Matter management wire
# surface; authenticated local reader transactions are covered in Crystal specs.
describe "Door Lock Aliro provisioning with official chip-tool" do
  device = E2E::Device["matter_door_lock_aliro"]
  timed = ["--timedInteractionTimeoutMs", "2000"]

  it "commissions an ALIRO lock without ALBU" do
    device.commission!
    feature_map = read_int(device, "doorlock", "feature-map", "FeatureMap")
    (feature_map & (1_i64 << 13)).should_not eq(0_i64)
    (feature_map & (1_i64 << 14)).should eq(0_i64)
    read_int(device, "doorlock", "number-of-aliro-credential-issuer-keys-supported", "NumberOfAliroCredentialIssuerKeysSupported").should eq(2_i64)
    read_int(device, "doorlock", "number-of-aliro-endpoint-keys-supported", "NumberOfAliroEndpointKeysSupported").should eq(2_i64)
  end

  it "requires timed Set/Clear, preserves reader config and public keys across restart, and clears across the lock" do
    signing = Matter::Crypto::Key.generate_key_pair
    group_id = Bytes.new(16, 0xA6_u8)
    config_args = ["hex:#{signing.private_key.hexstring}", "hex:#{signing.public_key.hexstring}", "hex:#{group_id.hexstring}"]

    expect_failure(device.invoke("doorlock", "set-aliro-reader-config", config_args), "NEEDS_TIMED_INTERACTION")
    expect_success(device.invoke("doorlock", "set-aliro-reader-config", config_args, options: timed))
    expect_failure(device.invoke("doorlock", "set-aliro-reader-config", config_args, options: timed), "INVALID_IN_STATE")

    reader_key = expect_success(device.read("doorlock", "aliro-reader-verification-key"))
    reader_key.output.downcase.should contain(signing.public_key.hexstring)
    group = expect_success(device.read("doorlock", "aliro-reader-group-identifier"))
    group.output.downcase.should contain(group_id.hexstring)
    expect_success(device.read("doorlock", "aliro-reader-group-sub-identifier"))
    expect_success(device.read("doorlock", "aliro-expedited-transaction-supported-protocol-versions"))

    endpoint = Matter::Crypto::Key.generate_key_pair
    credential = %({"credentialType":8,"credentialIndex":1})
    set_key = device.invoke("doorlock", "set-credential",
      ["0", credential, "hex:#{endpoint.public_key.hexstring}", "1", "1", "0"], options: timed)
    expect_success(set_key)
    status = expect_success(device.invoke("doorlock", "get-credential-status", [credential]))
    status.bool("credentialExists").should be_true
    status.output.downcase.should contain(endpoint.public_key.hexstring)

    device.restart!
    device.operational?.should be_true
    expect_success(device.read("doorlock", "aliro-reader-verification-key")).output.downcase.should contain(signing.public_key.hexstring)
    expect_success(device.invoke("doorlock", "get-credential-status", [credential])).output.downcase.should contain(endpoint.public_key.hexstring)

    expect_failure(device.invoke("doorlock", "clear-aliro-reader-config"), "NEEDS_TIMED_INTERACTION")
    expect_success(device.invoke("doorlock", "clear-aliro-reader-config", options: timed))
    expect_success(device.read("doorlock", "aliro-reader-verification-key"))
    expect_success(device.read("doorlock", "aliro-reader-group-identifier"))

    device.restart!
    device.operational?.should be_true
    expect_success(device.invoke("doorlock", "set-aliro-reader-config", config_args, options: timed))
  end
end
