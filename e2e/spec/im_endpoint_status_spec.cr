require "./e2e_helper"

# The switch has endpoint 1 with OnOff, but no LevelControl or DoorLock;
# endpoint 99 does not exist. These paths distinguish missing endpoints from
# missing clusters in official chip-tool responses.
describe "Interaction Model concrete path statuses" do
  device = E2E::Device["matter_switch"]
  missing_endpoint = 99

  it "commissions the switch" do
    device.commission!
  end

  it "distinguishes Read statuses" do
    device.read("onoff", "on-off", missing_endpoint).im_status.should eq("UNSUPPORTED_ENDPOINT")
    device.read("levelcontrol", "current-level", 1).im_status.should eq("UNSUPPORTED_CLUSTER")
  end

  it "distinguishes Write statuses" do
    device.write("onoff", "on-time", 10, missing_endpoint).im_status.should eq("UNSUPPORTED_ENDPOINT")
    device.write("levelcontrol", "on-level", 100, 1).im_status.should eq("UNSUPPORTED_CLUSTER")
  end

  it "distinguishes Invoke statuses" do
    device.invoke("onoff", "on", endpoint: missing_endpoint).im_status.should eq("UNSUPPORTED_ENDPOINT")
    device.invoke("levelcontrol", "move-to-level", ["100", "0", "0", "0"], 1).im_status.should eq("UNSUPPORTED_CLUSTER")
  end

  it "distinguishes Event Read statuses" do
    device.chip("doorlock", "read-event", "lock-operation", device.node, missing_endpoint.to_s)
      .im_status.should eq("UNSUPPORTED_ENDPOINT")
    device.chip("doorlock", "read-event", "lock-operation", device.node, "1")
      .im_status.should eq("UNSUPPORTED_CLUSTER")
  end
end
