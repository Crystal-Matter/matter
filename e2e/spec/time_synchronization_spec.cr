require "./e2e_helper"

describe "Matter 1.6 Time Synchronization TimeZone with official chip-tool" do
  device = E2E::Device["matter_time_zone"]
  zone = %([{"offset":36000,"validAt":0,"name":"Australia/Sydney"}])
  no_dst = %([{"offset":0,"validStarting":0,"validUntil":null}])
  dst = %([{"offset":3600,"validStarting":0,"validUntil":null}])
  overlapping_dst = %([{"offset":3600,"validStarting":0,"validUntil":2000000},{"offset":0,"validStarting":1000000,"validUntil":null}])

  it "commissions a root TimeZone server and updates local time and durable offsets" do
    device.commission!
    read_int(device, "timesynchronization", "cluster-revision", "ClusterRevision", 0).should eq(2_i64)
    read_int(device, "timesynchronization", "feature-map", "FeatureMap", 0).should eq(3_i64)
    read_int(device, "timesynchronization", "time-zone-list-max-size", "TimeZoneListMaxSize", 0).should eq(2_i64)
    read_int(device, "timesynchronization", "dstoffset-list-max-size", "DSTOffsetListMaxSize", 0).should eq(4_i64)

    response = expect_success(device.invoke("timesynchronization", "set-time-zone", [zone], endpoint: 0))
    response.bool("DSTOffsetRequired").should be_true
    expect_success(device.read("timesynchronization", "time-zone", 0)).output.should contain("Australia/Sydney")
    expect_success(device.invoke("timesynchronization", "set-dstoffset", [no_dst], endpoint: 0))
    expect_success(device.invoke("timesynchronization", "set-utctime", ["1000000000", "4"], endpoint: 0))
    standard = read_int(device, "timesynchronization", "local-time", "LocalTime", 0)
    standard.should be >= 37_000_000_000_i64

    expect_success(device.invoke("timesynchronization", "set-dstoffset", [dst], endpoint: 0))
    summer = read_int(device, "timesynchronization", "local-time", "LocalTime", 0)
    (summer - standard).should be >= 3_599_000_000_i64
    expect_failure(device.invoke("timesynchronization", "set-time-zone",
      [%([{"offset":50401,"validAt":0}])], endpoint: 0), "CONSTRAINT_ERROR")
    expect_failure(device.invoke("timesynchronization", "set-dstoffset", [overlapping_dst], endpoint: 0),
      "CONSTRAINT_ERROR")
    expect_success(device.read("timesynchronization", "time-zone", 0)).output.should contain("Australia/Sydney")
    expect_success(device.read("timesynchronization", "dstoffset", 0)).output.should contain("3600")

    device.restart!
    expect_success(device.read("timesynchronization", "time-zone", 0)).output.should contain("Australia/Sydney")
    expect_success(device.read("timesynchronization", "dstoffset", 0)).output.should contain("3600")
    expect_success(device.read("timesynchronization", "local-time", 0)).output.downcase.should contain("null")
  end

  it "sets and persists an IPv6 NTP fallback while rejecting a domain without DNS" do
    device.commission!
    expect_success(device.read("timesynchronization", "default-ntp", 0)).output.downcase.should contain("null")
    expect_success(device.read("timesynchronization", "supports-dns-resolve", 0)).bool("SupportsDNSResolve").should be_false
    expect_success(device.invoke("timesynchronization", "set-default-ntp", ["2001:db8::123"], endpoint: 0))
    expect_failure(device.invoke("timesynchronization", "set-default-ntp", ["pool.ntp.org"], endpoint: 0),
      "INVALID_COMMAND")
    expect_success(device.read("timesynchronization", "default-ntp", 0)).output.should contain("2001:db8::123")
    device.restart!
    expect_success(device.read("timesynchronization", "default-ntp", 0)).output.should contain("2001:db8::123")
  end
end
