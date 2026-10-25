require "../spec_helper"

private alias TimeSync = Matter::Cluster::TimeSynchronization

private def ntps_request : Bytes
  packet = Bytes.new(48, 0_u8)
  packet[0] = 0x23_u8
  packet[40, 8].copy_from(Bytes[1, 2, 3, 4, 5, 6, 7, 8])
  packet
end

describe "Time Synchronization NTPS" do
  it "only declares NTPServerAvailable for an opt-in server" do
    base = TimeSync.new(endpoint(0))
    base.get_attribute_metadata(TimeSync::ATTR_NTP_SERVER_AVAILABLE).should be_nil
    expect_raises(Matter::ConfigurationError) { TimeSync::SntpServer.new(base, "::1", 0).start }
    server = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::NtpServer)
    read(server, TimeSync::ATTR_NTP_SERVER_AVAILABLE).should be_false
    server.feature_map.value.should eq(4_u32)
  end

  it "echoes the origin token and rejects malformed or unsynchronized requests" do
    request = ntps_request
    TimeSync::SntpServer.respond(request, nil).should be_nil
    response = TimeSync::SntpServer.respond(request, 123_500_000_u64).as(Bytes)
    response.size.should eq(48)
    response[0].should eq(0x24_u8)
    response[1].should eq(2_u8)
    response[3].should eq(0_u8)
    response[24, 8].should eq(request[40, 8])
    TimeSync::SntpClient.decode(response, request[40, 8]).should eq(123_500_000_u64)
    TimeSync::SntpServer.respond(request, 123_500_000_u64, TimeSync::Granularity::Microseconds).as(Bytes)[3]
      .should eq(0xEC_u8)
    request[0] = 0x24_u8
    TimeSync::SntpServer.respond(request, 123_500_000_u64).should be_nil
    TimeSync::SntpServer.respond(Bytes[0x23], 123_500_000_u64).should be_nil
    TimeSync::SntpServer.respond(Bytes.new(49, 0x23_u8), 123_500_000_u64).should be_nil
    TimeSync::SntpServer.respond(ntps_request, 123_500_000_u64, TimeSync::Granularity::Minutes).should be_nil
    TimeSync::SntpServer.respond(ntps_request, UInt64::MAX).should be_nil
  end

  it "serves UDP only while bound and synchronized, then clears availability" do
    server = TimeSync.new(endpoint(0), feature_map: TimeSync::Feature::NtpServer)
    responder = TimeSync::SntpServer.new(server, "::1", 0)
    responder.start
    begin
      read(server, TimeSync::ATTR_NTP_SERVER_AVAILABLE).should be_false
      server.apply_utc_time(TimeSync::SetUtcTimeRequest.new(123_500_000_u64, TimeSync::Granularity::Minutes))
      read(server, TimeSync::ATTR_NTP_SERVER_AVAILABLE).should be_false
      server.apply_utc_time(TimeSync::SetUtcTimeRequest.new(123_500_000_u64, TimeSync::Granularity::Seconds))
      read(server, TimeSync::ATTR_NTP_SERVER_AVAILABLE).should be_true
      result = TimeSync::SntpClient.query("::1", responder.port)
      result.should_not be_nil
      result.as(UInt64).should be >= 123_500_000_u64
      server.report_time_failure
      read(server, TimeSync::ATTR_NTP_SERVER_AVAILABLE).should be_false
    ensure
      responder.stop
    end
    read(server, TimeSync::ATTR_NTP_SERVER_AVAILABLE).should be_false
  end
end
