require "./e2e_helper"

describe "synthetic Thread Border Router Management interoperability" do
  device = E2E::Device["matter_thread_border_router"]
  dataset = "hex:0e0800000000000c0001000300000f350407fff800020839758ec8144b07fb0708fdf1f1add0797dc00510f366cec7a446bab978d90d27abe38f23030f4f70656e5468726561642d353933380102593804103ca67c969efb0d0c74a4d8ee923b576c0c0402a0f7f8"
  pending = "hex:330800000000000c0002340400002710" + dataset[4..]
  timed = ["--timedInteractionTimeoutMs", "3000"]

  it "requires a timed, armed CASE activation and shares the resulting dataset across fabrics" do
    device.commission!
    read_int(device, "threadborderroutermanagement", "cluster-revision", "ClusterRevision", 1).should eq(1_i64)
    empty = expect_success(device.invoke("threadborderroutermanagement", "get-active-dataset-request", endpoint: 1))
    empty.output.should contain("Dataset")
    expect_success(device.read("threadborderroutermanagement", "active-dataset-timestamp", 1)).output
      .should match(/ActiveDatasetTimestamp:\s*(?:<)?null(?:>)?/i)

    request = [dataset]
    breadcrumb = ["--Breadcrumb", "9"]
    expect_failure(device.invoke("threadborderroutermanagement", "set-active-dataset-request", request, endpoint: 1, options: breadcrumb),
      "NEEDS_TIMED_INTERACTION")
    expect_failure(device.invoke("threadborderroutermanagement", "set-active-dataset-request", request, endpoint: 1, options: timed + breadcrumb),
      "FAILSAFE_REQUIRED")
    expect_success(device.invoke("generalcommissioning", "arm-fail-safe", ["60", "0"], endpoint: 0))
    expect_failure(device.invoke("threadborderroutermanagement", "set-active-dataset-request", ["hex:0001ff"], endpoint: 1, options: timed + breadcrumb),
      "INVALID_COMMAND")
    expect_success(device.invoke("threadborderroutermanagement", "set-active-dataset-request", request, endpoint: 1, options: timed + breadcrumb))
    read_int(device, "generalcommissioning", "breadcrumb", "Breadcrumb", 0).should eq(9_i64)
    read_int(device, "threadborderroutermanagement", "active-dataset-timestamp", "ActiveDatasetTimestamp", 1).should eq(786433_i64)
    expect_success(device.read("threadborderroutermanagement", "interface-enabled", 1)).bool("InterfaceEnabled").should be_true
    expect_failure(device.invoke("threadborderroutermanagement", "set-active-dataset-request", request, endpoint: 1, options: timed + breadcrumb),
      "INVALID_IN_STATE")
    # Re-arm briefly and let the real General Commissioning timer roll back
    # the backend before creating a second fabric.
    expect_success(device.invoke("generalcommissioning", "arm-fail-safe", ["1", "0"], endpoint: 0))
    sleep 2.seconds
    expect_success(device.read("threadborderroutermanagement", "active-dataset-timestamp", 1)).output
      .should match(/ActiveDatasetTimestamp:\s*(?:<)?null(?:>)?/i)
    expect_success(device.invoke("generalcommissioning", "arm-fail-safe", ["60", "0"], endpoint: 0))
    expect_success(device.invoke("threadborderroutermanagement", "set-active-dataset-request", request, endpoint: 1, options: timed + breadcrumb))
    expect_success(device.invoke("generalcommissioning", "commissioning-complete", endpoint: 0))

    window = expect_success(device.chip(["pairing", "open-commissioning-window", device.node, "1", "180", "1000", "3840"]))
    code = window.output.match(/Manual pairing code:\s*\[?([0-9]{4}-[0-9]{3}-[0-9]{4}|[0-9]{11})\]?/i)
      .try(&.[1]) || fail("no enhanced-window pairing code in chip-tool output\n#{window.tail}")
    second_storage = File.join(E2E::STORAGE_ROOT, "matter_thread_border_router_second")
    Dir.mkdir_p(second_storage)
    expect_success(E2E.run(["pairing", "code", "2", code], second_storage))
    second = expect_success(E2E.run(
      ["threadborderroutermanagement", "get-active-dataset-request", "2", "1"], second_storage))
    second.output.should contain("Received Command Response Data, Endpoint=1 Cluster=0x0000_0452 Command=0x0000_0002")
    second.output.should contain("DatasetResponse:")
    second.output.should match(/\bdataset:\s*#{dataset[4..]}/i)

    expect_success(device.invoke("threadborderroutermanagement", "set-pending-dataset-request", [pending], endpoint: 1, options: timed))
    read_int(device, "threadborderroutermanagement", "pending-dataset-timestamp", "PendingDatasetTimestamp", 1).should eq(786434_i64)
    second_pending = expect_success(E2E.run(
      ["threadborderroutermanagement", "get-pending-dataset-request", "2", "1"], second_storage))
    second_pending.output.should contain("Received Command Response Data, Endpoint=1 Cluster=0x0000_0452 Command=0x0000_0002")
    second_pending.output.should contain("DatasetResponse:")
    second_pending.output.should match(/\bdataset:\s*#{pending[4..]}/i)

    view_acl = %([{"fabricIndex":1,"privilege":1,"authMode":2,"subjects":[],"targets":[]}])
    expect_success(device.write("accesscontrol", "acl", view_acl, 0))
    expect_failure(device.invoke("threadborderroutermanagement", "get-active-dataset-request", endpoint: 1), "UNSUPPORTED_ACCESS")
  end
end
