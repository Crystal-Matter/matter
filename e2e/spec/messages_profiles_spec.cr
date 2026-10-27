require "./e2e_helper"

module MessagesProfilesE2E
  MATTER_EPOCH_UNIX_SECONDS = 946_684_800_i64
end

describe "Messages confirmation profiles through chip-tool" do
  device = E2E::Device["matter_content_app_messages"]

  it "advertises CONF, RESP and RPLY and records a host confirmation" do
    device.commission!
    read_int(device, "messages", "feature-map", "FeatureMap").should eq(7)
    id = "504132435465768798a9bacbdcedfe0f"
    responses = %([{"messageResponseID":2,"label":"Yes"}])
    expect_success(device.invoke("messages", "present-messages-request",
      ["hex:#{id}", "1", "7", "null", "null", "Confirm in demo UI"],
      options: ["--Responses", responses]))
    presented = expect_success(device.chip("messages", "read-event", "message-presented", device.node, "1"))
    presented.output.downcase.should contain(id.downcase)
    complete = expect_success(device.chip("messages", "read-event", "message-complete", device.node, "1"))
    complete.output.downcase.should contain(id.downcase)
    complete.output.should contain("ResponseID: 2")
    complete.output.should contain("Reply: Seen")
    expect_success(device.read("messages", "messages")).output.should contain("Messages: 0 entries")
  end

  it "restores and cancels a pending confirmation after restart" do
    device.commission!
    id = "604132435465768798a9bacbdcedfe0f"
    expect_success(device.invoke("messages", "present-messages-request",
      ["hex:#{id}", "1", "1", "null", "null", "Waiting for user"],
      options: ["--Responses", "[]"]))
    expect_success(device.read("messages", "active-message-ids")).output.downcase.should contain(id.downcase)
    device.restart!
    expect_success(device.read("messages", "messages")).output.downcase.should contain(id.downcase)
    expect_success(device.read("messages", "active-message-ids")).output.downcase.should contain(id.downcase)
    expect_success(device.invoke("messages", "cancel-messages-request", ["[\"hex:#{id}\"]"]))
    expect_success(device.read("messages", "messages")).output.should contain("Messages: 0 entries")
  end

  it "presents a queued message when its future StartTime arrives" do
    device.commission!
    id = "704132435465768798a9bacbdcedfe0f"
    start_time = Time.utc.to_unix - MessagesProfilesE2E::MATTER_EPOCH_UNIX_SECONDS + 4
    expect_success(device.invoke("messages", "present-messages-request",
      ["hex:#{id}", "1", "1", start_time.to_s, "10000", "Future notice"],
      options: ["--Responses", "[]"]))
    expect_success(device.read("messages", "active-message-ids")).output.downcase.should_not contain(id.downcase)
    sleep 5.seconds
    expect_success(device.read("messages", "active-message-ids")).output.downcase.should contain(id.downcase)
    expect_success(device.invoke("messages", "cancel-messages-request", ["[\"hex:#{id}\"]"]))
  end
end
