require "./e2e_helper"

# chip-tool is the independent Matter SDK peer. Its allow-large-payload option
# selects a TCP CASE session, and its ExchangeManager logs each decrypted IM
# packet's full wire byte count as (B:n).
module TcpLargePayloadE2E
  LABEL_COUNT      =   96
  UDP_PACKET_LIMIT = 1280

  def self.wait_for_output(path : String, timeout : Time::Span, & : String -> Bool) : String
    deadline = Time.instant + timeout
    loop do
      output = File.exists?(path) ? E2E.strip_ansi(File.read(path)) : ""
      return output if yield output
      raise "Timed out waiting for chip-tool subscription:\n#{output.lines.last(50).join}" if Time.instant >= deadline
      sleep 200.milliseconds
    end
  end
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

  it "receives every entry of a large active subscription update over UDP chunks" do
    trigger = File.join(E2E::LOG_DIR, "matter_tcp_large_payload.trigger")
    ack = "#{trigger}.ack"
    log_path = File.join(E2E::LOG_DIR, "matter_tcp_large_payload_subscription.log")
    File.delete(trigger) if File.exists?(trigger)
    File.delete(ack) if File.exists?(ack)

    File.open(log_path, "w") do |log|
      process = Process.new(E2E::CHIP_TOOL,
        ["interactive", "start", "--storage-directory", device.storage_dir],
        input: Process::Redirect::Pipe, output: log, error: log)
      begin
        process.input.puts("userlabel subscribe label-list 0 30 #{device.node} 1")
        process.input.flush
        TcpLargePayloadE2E.wait_for_output(log_path, 20.seconds) do |output|
          output.includes?("IM:SubscribeResponse")
        end

        nonce = "update:#{Time.utc.to_unix_ms}"
        File.write("#{trigger}.tmp", nonce)
        File.rename("#{trigger}.tmp", trigger)
        TcpLargePayloadE2E.wait_for_output(ack, 10.seconds) { |value| value == nonce }

        output = TcpLargePayloadE2E.wait_for_output(log_path, 20.seconds) do |text|
          text.scan(/\bValue:\s*Update \d{6}/).size >= TcpLargePayloadE2E::LABEL_COUNT &&
            text.scan(/\bMsg TX\b[^\n]*\(IM:StatusResponse\)/).size > 2
        end
        values = [] of String
        output.scan(/\bValue:\s*(Update \d{6})/) { |match| values << match[1] }
        values.should eq(Array.new(TcpLargePayloadE2E::LABEL_COUNT) { |i| "Update #{i.to_s.rjust(6, '0')}" }), output

        reports = [] of Tuple(String, Int32)
        output.scan(/\[E:(\d+[ir])\b[^\n]*\bMsg RX\b[^\n]*\(IM:ReportData\) \(B:(\d+)\)/) do |match|
          reports << {match[1], match[2].to_i}
        end
        reports.size.should be > 2, output # Initial report plus multiple update chunks.
        update_exchange = reports[1][0]
        update_exchange.should_not eq(reports[0][0]), output
        reports.skip(1).all? { |exchange, _| exchange == update_exchange }.should be_true, output
        reports.max_of(&.[1]).should be < TcpLargePayloadE2E::UDP_PACKET_LIMIT, output

        status_exchanges = [] of String
        output.scan(/\[E:(\d+[ir])\b[^\n]*\bMsg TX\b[^\n]*\(IM:StatusResponse\)/) do |match|
          status_exchanges << match[1]
        end
        status_exchanges.count(update_exchange).should eq(reports.size - 1), output
      ensure
        process.terminate rescue nil
        process.wait rescue nil
      end
    end
  end
end
