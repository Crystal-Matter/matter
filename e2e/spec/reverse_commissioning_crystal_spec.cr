require "./e2e_helper"
require "../../src/matter/controller"

module ReverseCommissioningCrystalE2E
  REQUEST_ID         = "7003"
  TARGET_VENDOR_ID   = "65521"
  TARGET_PRODUCT_ID  = "4661"
  SOURCE_TARGET_ID   = 0xA103_u64
  WINDOW_PATH        = "/e2e/logs/reverse-window.json"
  CONTROLLER_PATH    = "/e2e/logs/reverse-controller.yml"
  COMPLETION_TIMEOUT = 90.seconds
  COMPLETION_POLL    = 0.5.seconds

  def self.wait_for_completion(host : E2E::Device) : Nil
    deadline = Time.instant + COMPLETION_TIMEOUT
    until host.log.includes?("Reverse commissioning complete: request=#{REQUEST_ID}")
      if Time.instant >= deadline
        raise E2E::CommissioningError.new("Crystal reverse commissioning did not complete\n#{host.log_tail}")
      end
      sleep COMPLETION_POLL
    end
  end
end

describe "real Crystal target reverse commissioning" do
  host = E2E::Device["matter_reverse_commissioning"]
  target = E2E::Device["matter_reverse_target"]

  it "opens the approved target window and commissions it onto the host source fabric" do
    host.commission!
    target.commission!
    File.delete(ReverseCommissioningCrystalE2E::WINDOW_PATH) if File.exists?(ReverseCommissioningCrystalE2E::WINDOW_PATH)

    expect_success(host.invoke("commissionercontrol", "request-commissioning-approval",
      [ReverseCommissioningCrystalE2E::REQUEST_ID,
       ReverseCommissioningCrystalE2E::TARGET_VENDOR_ID,
       ReverseCommissioningCrystalE2E::TARGET_PRODUCT_ID], endpoint: 1))
    approval = expect_success(host.chip(["commissionercontrol", "read-event",
                                         "commissioning-request-result", host.node, "1"]))
    approval.int("StatusCode").should eq(0_i64), approval.output

    response = expect_success(host.invoke("commissionercontrol", "commission-node",
      [ReverseCommissioningCrystalE2E::REQUEST_ID, "30"], endpoint: 1))
    response.output.should contain("ReverseOpenCommissioningWindow")
    window = JSON.parse(File.read(ReverseCommissioningCrystalE2E::WINDOW_PATH))
    response.int("commissioningTimeout").should eq(window["commissioning_timeout"].as_i64), response.output
    response.int("discriminator").should eq(window["discriminator"].as_i64), response.output

    expect_success(target.chip(["administratorcommissioning", "open-commissioning-window",
                                window["commissioning_timeout"].as_i64.to_s,
                                "hex:#{window["verifier"].as_s}",
                                window["discriminator"].as_i64.to_s,
                                window["iterations"].as_i64.to_s,
                                "hex:#{window["salt"].as_s}",
                                target.node, "0", "--timedInteractionTimeoutMs", "10000"]))

    ReverseCommissioningCrystalE2E.wait_for_completion(host)
    state = Matter::Controller::StateStore.new(
      Matter::Storage::YamlFile.new(ReverseCommissioningCrystalE2E::CONTROLLER_PATH)).load
    state.nodes.has_key?(ReverseCommissioningCrystalE2E::SOURCE_TARGET_ID).should be_true
    fabrics = expect_success(target.read("operationalcredentials", "commissioned-fabrics", 0))
    fabrics.int("CommissionedFabrics").should eq(2_i64), fabrics.output
  end
end
