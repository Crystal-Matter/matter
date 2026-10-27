require "./spec_helper"
require "../e2e/spec/e2e_helper"

private class RetryReadDevice < E2E::Device
  getter calls = 0

  def initialize(@replies : Array(E2E::Result))
    super("matter_retry_read")
  end

  def chip(args : Array(String), timeout : Time::Span = E2E::COMMAND_TIMEOUT) : E2E::Result
    @calls += 1
    @replies.shift
  end
end

describe "E2E read transport retry" do
  it "retries one CASE setup timeout for an idempotent attribute read" do
    command = ["onoff", "read", "on-off", "1", "1"]
    timeout = E2E::Result.new(command, 1,
      "CASESession timed out while waiting for a response from peer\nRun command failure")
    success = E2E::Result.new(command, 0, "[TOO] OnOff: TRUE")
    device = RetryReadDevice.new([timeout, success])

    device.read("onoff", "on-off").success?.should be_true
    device.calls.should eq(2)
  end

  it "does not retry an interaction model error or repeated CASE timeout" do
    command = ["onoff", "read", "on-off", "1", "1"]
    invalid = E2E::Result.new(command, 1, "General error: 0x7E (UNSUPPORTED_ACCESS)")
    device = RetryReadDevice.new([invalid])
    device.read("onoff", "on-off").should be(invalid)
    device.calls.should eq(1)

    timeout = E2E::Result.new(command, 1,
      "CASESession timed out while waiting for a response from peer\nRun command failure")
    device = RetryReadDevice.new([timeout, timeout])
    device.read("onoff", "on-off").should be(timeout)
    device.calls.should eq(2)
  end

  it "does not retry a final interaction model error after an earlier CASE timeout log" do
    command = ["onoff", "read", "on-off", "1", "1"]
    failure = E2E::Result.new(command, 1,
      "CASESession timed out while waiting for a response from peer\nGeneral error: 0x7E (UNSUPPORTED_ACCESS)\nRun command failure")
    device = RetryReadDevice.new([failure])

    device.read("onoff", "on-off").should be(failure)
    device.calls.should eq(1)
  end
end
