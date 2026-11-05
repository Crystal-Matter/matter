require "./e2e_helper"

describe "Messages protected presentation through chip-tool" do
  device = E2E::Device["matter_content_app_protected_messages"]

  it "advertises PROT and presents a protected message after test-host authentication" do
    device.commission!
    read_int(device, "messages", "feature-map", "FeatureMap").should eq(8)
    id = "804132435465768798a9bacbdcedfe0f"
    expect_success(device.invoke("messages", "present-messages-request",
      ["hex:#{id}", "1", "16", "null", "null", "Protected demo notice"]))
    presented = expect_success(device.chip("messages", "read-event", "message-presented", device.node, "1"))
    presented.output.downcase.should contain(id.downcase)
    expect_success(device.read("messages", "active-message-ids")).output.downcase.should contain(id.downcase)
    expect_success(device.invoke("messages", "cancel-messages-request", ["[\"hex:#{id}\"]"]))
  end
end
