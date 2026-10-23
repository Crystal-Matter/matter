require "./e2e_helper"

private SERVICE_AREA = "servicearea"

describe "Matter 1.6 Service Area interoperability" do
  device = E2E::Device["matter_rvc"]

  it "commissions and reads the rev2 area catalogue and feature gates" do
    device.commission!
    read_int(device, SERVICE_AREA, "cluster-revision", "ClusterRevision", 1).should eq(2_i64)
    read_int(device, SERVICE_AREA, "feature-map", "FeatureMap", 1).should eq(0_i64)
    catalogue = expect_success(device.read(SERVICE_AREA, "supported-areas", 1)).output
    catalogue.should contain("Kitchen")
    catalogue.should contain("Hall")
    read_int(device, SERVICE_AREA, "current-area", "CurrentArea", 1).should eq(1_i64)
    expect_failure(device.chip("any", "read-by-id", "0x150", "0x1", device.node, "1"), "UNSUPPORTED_ATTRIBUTE")
  end

  it "selects, deduplicates, rejects unsupported areas, and rejects active changes" do
    response = expect_success(device.invoke(SERVICE_AREA, "select-areas", ["[2,1,2]"], endpoint: 1))
    response.int("status").should eq(0_i64)
    expect_success(device.read(SERVICE_AREA, "selected-areas", 1)).int_list("SelectedAreas").should eq([2_i64, 1_i64])
    response = expect_success(device.invoke(SERVICE_AREA, "select-areas", ["[9]"], endpoint: 1))
    response.int("status").should eq(1_i64)
    expect_success(device.read(SERVICE_AREA, "selected-areas", 1)).int_list("SelectedAreas").should eq([2_i64, 1_i64])

    expect_success(device.invoke("rvcrunmode", "change-to-mode", ["1"], endpoint: 1))
    response = expect_success(device.invoke(SERVICE_AREA, "select-areas", ["[1]"], endpoint: 1))
    response.int("status").should eq(2_i64)
    response.output.should contain("Area selection is unavailable")
    skipped = expect_success(device.invoke(SERVICE_AREA, "skip-area", ["2"], endpoint: 1))
    skipped.int("status").should eq(0_i64)
    read_int(device, "rvcoperationalstate", "operational-state", "OperationalState", 1).should eq(0_i64)
    expect_success(device.invoke("rvcrunmode", "change-to-mode", ["0"], endpoint: 1))
  end

  it "restores selected areas after the device restarts" do
    device.restart!
    expect_success(device.read(SERVICE_AREA, "selected-areas", 1)).int_list("SelectedAreas").should eq([2_i64, 1_i64])
    response = expect_success(device.invoke(SERVICE_AREA, "select-areas", ["[]"], endpoint: 1))
    response.int("status").should eq(0_i64)
    expect_success(device.read(SERVICE_AREA, "selected-areas", 1)).int_list("SelectedAreas").should be_empty
  end
end
