require "./e2e_helper"

private CHIME_CLUSTER  = "0x556"
private CHIME_ENDPOINT = "1"

private def read_chime(device : E2E::Device, attribute : UInt32) : Int64
  result = expect_success(device.chip("any", "read-by-id", CHIME_CLUSTER,
    "0x#{attribute.to_s(16)}", device.node, CHIME_ENDPOINT))
  value = result.output.scan(/\bData = (-?\d+)\b/).last?
  value.try(&.[1].to_i64) || fail("#{result.command}: no numeric data in chip-tool response\n#{result.tail}")
end

describe "Matter 1.6 Chime interoperability" do
  device = E2E::Device["matter_chime"]

  it "commissions and reads the installed sounds and revision two" do
    device.commission!
    read_chime(device, 0xFFFD_u32).should eq(2_i64)
    read_chime(device, 0x0001_u32).should eq(1_i64)
    expect_success(device.read("chime", "installed-chime-sounds")).output.should contain("Classic")
  end

  it "selects and plays a sound, then reports the started event" do
    expect_failure(device.write("chime", "selected-chime", 3), "NOT_FOUND")
    expect_success(device.write("chime", "selected-chime", 2))
    expect_success(device.chip("any", "command-by-id", CHIME_CLUSTER,
      "0x0", "{}", device.node, CHIME_ENDPOINT))
    started = expect_success(device.chip(["chime", "read-event", "chime-started-playing", device.node, CHIME_ENDPOINT]))
    started.output.should contain("ChimeID")
    started.output.should contain("2")
  end

  it "disables playback and persists selection and enablement across restart" do
    expect_success(device.write("chime", "enabled", "false"))
    expect_failure(device.chip("any", "command-by-id", CHIME_CLUSTER,
      "0x0", "{}", device.node, CHIME_ENDPOINT), "INVALID_IN_STATE")
    device.restart!
    read_chime(device, 0x0001_u32).should eq(2_i64)
    expect_success(device.read("chime", "enabled")).bool("Enabled").should be_false
    expect_success(device.write("chime", "enabled", "true"))
    expect_success(device.chip("any", "command-by-id", CHIME_CLUSTER,
      "0x0", %({"0": "u:1"}), device.node, CHIME_ENDPOINT))
  end
end
