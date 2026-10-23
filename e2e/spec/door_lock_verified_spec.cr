require "./e2e_helper"

# The trigger file models a physical RFID reader input outside the Matter wire.
# The fixture's verifier is test-only; deployed readers authenticate hardware
# transactions and freshness before naming a stored credential.
describe "Door Lock verified RFID host input with official chip-tool" do
  device = E2E::Device["matter_door_lock_verified"]
  timed = ["--timedInteractionTimeoutMs", "2000"]
  trigger = File.join(E2E::LOG_DIR, "matter_door_lock_verified.trigger")
  ack = "#{trigger}.ack"

  present = ->(prefix : String) do
    File.delete(ack) if File.exists?(ack)
    token = "#{prefix}:#{Time.utc.to_unix_ms}"
    File.write("#{trigger}.tmp", token)
    File.rename("#{trigger}.tmp", trigger)
    deadline = Time.instant + 10.seconds
    until File.exists?(ack) && File.read(ack).starts_with?("#{token}:")
      raise "Verified RFID host did not acknowledge #{token}" if Time.instant >= deadline
      sleep 100.milliseconds
    end
    File.read(ack)
  end

  it "commissions with only the RFID credential feature advertised" do
    device.commission!
    feature_map = read_int(device, "doorlock", "feature-map", "FeatureMap")
    (feature_map & (1_i64 << 1)).should_not eq(0_i64)
    (feature_map & (1_i64 << 2)).should eq(0_i64)
    (feature_map & (1_i64 << 6)).should eq(0_i64)
    (feature_map & (1_i64 << 14)).should eq(0_i64)
  end

  it "manages RFID over Matter and unlocks only after a verified local presentation" do
    credential = %({"credentialType":2,"credentialIndex":1})
    add = Matter::Cluster::DoorLock::DataOperationType::Add.value.to_s
    result = expect_success(device.invoke("doorlock", "set-credential",
      [add, credential, "RFID1357", "2", "1", "0"], options: timed))
    result.int("status").should eq(Matter::Cluster::DoorLock::StatusCode::Success.value.to_i64), result.output
    status = expect_success(device.invoke("doorlock", "get-credential-status", [credential]))
    status.bool("credentialExists").should be_true
    status.int("userIndex").should eq(2_i64)

    present.call("invalid").should end_with(":false")
    read_int(device, "doorlock", "lock-state", "LockState").should eq(1_i64)
    present.call("verified").should end_with(":true")
    read_int(device, "doorlock", "lock-state", "LockState").should eq(2_i64)

    operation = expect_success(device.chip(["doorlock", "read-event", "lock-operation", device.node, "1"]))
    operation.output.should contain("LockOperation")
    operation.int("OperationSource").should eq(Matter::Cluster::DoorLock::OperationSource::Rfid.value.to_i64)

    device.restart!
    device.operational?.should be_true
    expect_success(device.invoke("doorlock", "get-credential-status", [credential])).bool("credentialExists").should be_true
    expect_success(device.invoke("doorlock", "lock-door", options: timed))
    present.call("verified").should end_with(":true")
    read_int(device, "doorlock", "lock-state", "LockState").should eq(2_i64)
  end
end
