require "./e2e_helper"

# chip-tool is the independent Matter SDK peer. Its allow-large-payload option
# selects a TCP CASE session, and its ExchangeManager logs each decrypted IM
# packet's full wire byte count as (B:n).
module TcpLargePayloadE2E
  LABEL_COUNT      =   96
  UDP_PACKET_LIMIT = 1280
end

describe "official SDK TCP large-payload interoperability" do
  device = E2E::Device["matter_tcp_large_payload"]

  it "commissions the opt-in TCP device over the ordinary UDP path" do
    device.commission!
  end

  it "receives an encrypted ReportData larger than a UDP Matter packet over TCP CASE" do
    response = expect_success(device.chip(
      "fixedlabel", "read", "label-list", device.node, "1", "--allow-large-payload", "1"))

    values = response.values("Value")
    values.size.should eq(TcpLargePayloadE2E::LABEL_COUNT), response.output
    values.first.should eq("TCP label 000000"), response.output
    values.last.should eq("TCP label #{(TcpLargePayloadE2E::LABEL_COUNT - 1).to_s.rjust(6, '0')}"), response.output

    report_sizes = [] of Int32
    response.output.scan(/\bMsg RX\b[^\n]*\(IM:ReportData\) \(B:(\d+)\)/) do |match|
      report_sizes << match[1].to_i
    end
    report_sizes.should_not be_empty, response.output
    report_sizes.max.should be > TcpLargePayloadE2E::UDP_PACKET_LIMIT, response.output
  end
end
