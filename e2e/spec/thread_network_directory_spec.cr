require "./e2e_helper"

describe "synthetic Thread Network Directory shared across fabrics" do
  device = E2E::Device["matter_thread_directory"]
  dataset = "hex:0e0800000000000c0001000300000f350407fff800020839758ec8144b07fb0708fdf1f1add0797dc00510f366cec7a446bab978d90d27abe38f23030f4f70656e5468726561642d353933380102593804103ca67c969efb0d0c74a4d8ee923b576c0c0402a0f7f8"
  xpan = "hex:39758ec8144b07fb"
  timed = ["--timedInteractionTimeoutMs", "2000"]

  it "commissions and advertises the revision 1 directory capacity" do
    device.commission!
    read_int(device, "threadnetworkdirectory", "cluster-revision", "ClusterRevision", 0).should eq(1_i64)
    read_int(device, "threadnetworkdirectory", "thread-network-table-size", "ThreadNetworkTableSize", 0).should be >= 32_i64
    expect_success(device.read("threadnetworkdirectory", "thread-networks", 0))
  end

  it "requires a timed AddNetwork and shares the resulting metadata" do
    expect_failure(device.invoke("threadnetworkdirectory", "add-network", [dataset], endpoint: 0), "NEEDS_TIMED_INTERACTION")
    expect_success(device.invoke("threadnetworkdirectory", "add-network", [dataset], endpoint: 0, options: timed))
    entry = expect_success(device.read("threadnetworkdirectory", "thread-networks", 0))
    entry.output.should contain("OpenThread-5938")
    entry.int("Channel").should eq(15_i64)
    expect_failure(device.invoke("threadnetworkdirectory", "add-network", [dataset], endpoint: 0, options: timed), "INVALID_IN_STATE")
  end

  it "returns the same credentials and metadata to a second fabric" do
    window = expect_success(device.chip(["pairing", "open-commissioning-window",
                                         device.node, "1", "180", "1000", "3840"]))
    pairing_code = window.output.match(/Manual pairing code:\s*\[?([0-9]{4}-[0-9]{3}-[0-9]{4}|[0-9]{11})\]?/i)
      .try(&.[1]) || fail("no enhanced-window pairing code in chip-tool output\n#{window.tail}")
    second_storage = File.join(E2E::STORAGE_ROOT, "matter_thread_directory_second")
    Dir.mkdir_p(second_storage)
    expect_success(E2E.run(["pairing", "code", "2", pairing_code], second_storage))

    second = expect_success(E2E.run(
      ["threadnetworkdirectory", "read", "thread-networks", "2", "0"], second_storage))
    second.output.should contain("OpenThread-5938")
    credential = expect_success(E2E.run(
      ["threadnetworkdirectory", "get-operational-dataset", xpan, "2", "0"], second_storage))
    second_dataset = credential.value("operationalDataset")
    second_dataset.should eq(dataset[4..].upcase)
    original = expect_success(device.invoke("threadnetworkdirectory", "get-operational-dataset", [xpan], endpoint: 0))
    original.value("operationalDataset").should eq(second_dataset)
  end

  it "protects the preferred network and retains credentials across restart" do
    expect_success(device.write("threadnetworkdirectory", "preferred-extended-pan-id", xpan, 0))
    expect_failure(device.invoke("threadnetworkdirectory", "remove-network", [xpan], endpoint: 0, options: timed),
      "CONSTRAINT_ERROR")
    device.restart!
    expect_success(device.read("threadnetworkdirectory", "thread-networks", 0)).output.should contain("OpenThread-5938")
    expect_success(device.invoke("threadnetworkdirectory", "get-operational-dataset", [xpan], endpoint: 0))
    expect_success(device.write("threadnetworkdirectory", "preferred-extended-pan-id", "null", 0))
    expect_success(device.invoke("threadnetworkdirectory", "remove-network", [xpan], endpoint: 0, options: timed))
    expect_failure(device.invoke("threadnetworkdirectory", "get-operational-dataset", [xpan], endpoint: 0), "NOT_FOUND")
  end
end
