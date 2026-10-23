require "./e2e_helper"

# examples/matter_door_lock_device.cr - Door Lock on endpoint 1 (PIN 2468 required)
describe "matter_door_lock example" do
  device = E2E::Device["matter_door_lock"]
  timed = ["--timedInteractionTimeoutMs", "2000"]
  pin = ["--PINCode", "2468"]

  locked = 1_i64
  unlocked = 2_i64

  it "commissions with chip-tool" do
    device.commission!
  end

  it "is a door lock" do
    expect_success(device.read("descriptor", "device-type-list", 1)).int("DeviceType").should eq 0x000A_i64
    expect_success(device.read("fixedlabel", "label-list")).values("Value").should eq ["Example Door Lock"]
  end

  it "reads the lock state" do
    read_int(device, "doorlock", "lock-state", "LockState").should be_in(0..3)
    read_bool(device, "doorlock", "require-pinfor-remote-operation", "RequirePINforRemoteOperation").should be_true
  end

  it "exposes valid operating modes and Matter 1.6 sound-volume values" do
    read_int(device, "doorlock", "supported-operating-modes", "SupportedOperatingModes").should eq(0xFFF6_i64)

    expect_success(device.write("doorlock", "sound-volume", 2))
    read_int(device, "doorlock", "sound-volume", "SoundVolume").should eq(2_i64)
    expect_success(device.write("doorlock", "sound-volume", 3))
    read_int(device, "doorlock", "sound-volume", "SoundVolume").should eq(3_i64)

    expect_failure(device.write("doorlock", "operating-mode", 1), "CONSTRAINT_ERROR")
    read_int(device, "doorlock", "operating-mode", "OperatingMode").should eq(0_i64)
    expect_success(device.write("doorlock", "operating-mode", 3))
    read_int(device, "doorlock", "operating-mode", "OperatingMode").should eq(3_i64)
    expect_failure(device.invoke("doorlock", "unlock-door", options: timed + pin), "FAILURE")
    expect_success(device.write("doorlock", "operating-mode", 0))
  end

  it "rejects an untimed unlock before changing lock state" do
    before = read_int(device, "doorlock", "lock-state", "LockState")
    result = device.invoke("doorlock", "unlock-door", options: pin)
    result.im_status.should eq("NEEDS_TIMED_INTERACTION"), result.output
    read_int(device, "doorlock", "lock-state", "LockState").should eq(before)
  end

  it "unlocks with the PIN" do
    expect_success(device.invoke("doorlock", "unlock-door", options: timed + pin))
    read_int(device, "doorlock", "lock-state", "LockState").should eq unlocked
  end

  it "locks with the PIN" do
    expect_success(device.invoke("doorlock", "lock-door", options: timed + pin))
    read_int(device, "doorlock", "lock-state", "LockState").should eq locked
  end

  it "rejects remote operation without a PIN" do
    result = device.invoke("doorlock", "unlock-door", options: timed)
    result.success?.should be_false
    read_int(device, "doorlock", "lock-state", "LockState").should eq locked
  end

  it "writes the AutoRelockTime attribute" do
    expect_success(device.write("doorlock", "auto-relock-time", 30, options: timed))
    read_int(device, "doorlock", "auto-relock-time", "AutoRelockTime").should eq 30
  end

  it "keeps a commissioned fabric, user, and PIN credential across restart" do
    credential = %({"credentialType":1,"credentialIndex":1})
    expect_success(device.invoke("doorlock", "set-user", ["0", "2", "Guest", "222", "1", "0", "0"], options: timed))
    expect_success(device.invoke("doorlock", "set-credential", ["0", credential, "1357", "2", "1", "0"], options: timed))
    expect_success(device.invoke("doorlock", "unlock-door", options: timed + ["--PINCode", "1357"]))

    device.restart!
    device.operational?.should be_true
    device.restart_log.should_not match(E2E::PAIRING_CODE_RE)

    get_user = expect_success(device.invoke("doorlock", "get-user", ["2"]))
    get_user.value("userName").should eq("Guest"), get_user.output
    expect_success(device.invoke("doorlock", "get-credential-status", [credential])).bool("credentialExists").should be_true
    expect_success(device.invoke("doorlock", "unlock-door", options: timed + ["--PINCode", "1357"]))
    read_int(device, "doorlock", "lock-state", "LockState").should eq unlocked

    expect_success(device.invoke("doorlock", "lock-door", options: timed + pin))
    read_int(device, "doorlock", "lock-state", "LockState").should eq locked
  end

  it "enforces a weekly access schedule after a device restart" do
    credential = %({"credentialType":1,"credentialIndex":2})
    scheduled_pin = ["--PINCode", "8642"]
    expect_success(device.invoke("doorlock", "set-user", ["0", "3", "Cleaner", "333", "1", "2", "0"], options: timed))
    expect_success(device.invoke("doorlock", "set-credential", ["0", credential, "8642", "3", "1", "2"], options: timed))
    expect_failure(device.invoke("doorlock", "unlock-door", options: timed + scheduled_pin), "FAILURE")

    # Every day, from midnight through the final second of 23:59.
    expect_success(device.invoke("doorlock", "set-week-day-schedule", ["1", "3", "127", "0", "0", "23", "59"], options: timed))
    expect_success(device.invoke("doorlock", "unlock-door", options: timed + scheduled_pin))
    expect_success(device.invoke("doorlock", "lock-door", options: timed + pin))

    device.restart!
    device.operational?.should be_true
    expect_success(device.invoke("doorlock", "unlock-door", options: timed + scheduled_pin))
    read_int(device, "doorlock", "lock-state", "LockState").should eq unlocked
  end

  it "consumes a disposable PIN only on a successful open and retains the disabled user after restart" do
    credential = %({"credentialType":1,"credentialIndex":3})
    disposable_pin = ["--PINCode", "5757"]
    expect_success(device.invoke("doorlock", "set-user", ["0", "4", "One Use", "444", "1", "6", "0"], options: timed))
    expect_success(device.invoke("doorlock", "set-credential", ["0", credential, "5757", "4", "1", "6"], options: timed))

    expect_success(device.invoke("doorlock", "lock-door", options: timed + disposable_pin))
    expect_success(device.invoke("doorlock", "unlock-door", options: timed + disposable_pin))
    expect_success(device.invoke("doorlock", "get-user", ["4"])).int("userStatus").should eq(3_i64)
    expect_failure(device.invoke("doorlock", "unlock-door", options: timed + disposable_pin), "FAILURE")

    device.restart!
    device.operational?.should be_true
    expect_success(device.invoke("doorlock", "get-user", ["4"])).int("userStatus").should eq(3_i64)
    expect_failure(device.invoke("doorlock", "unlock-door", options: timed + disposable_pin), "FAILURE")
  end
end
