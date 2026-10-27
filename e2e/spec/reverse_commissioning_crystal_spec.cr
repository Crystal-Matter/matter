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

  record Window, commissioning_timeout : UInt16, verifier_hex : String,
    discriminator : UInt16, iterations : UInt32, salt_hex : String

  # chip-tool logs a ByteSpan over multiple lines when it exceeds the logger's
  # line limit. Subsequent lines use a dotted field label of equal length.
  def self.parse_window(output : String) : Window
    fields = {} of String => String
    in_response = false
    bytes_field = nil.as(String?)
    output.each_line do |line|
      unless in_response
        if line.includes?("ReverseOpenCommissioningWindow: {")
          in_response = true
        end
        next
      end
      break if line.matches?(/\}\s*$/)
      if match = line.match(/\b(commissioningTimeout|PAKEPasscodeVerifier|discriminator|iterations|salt):\s*([0-9A-Fa-f]+)\s*$/)
        name = match[1]
        fields[name] = match[2]
        bytes_field = name.in?("PAKEPasscodeVerifier", "salt") ? name : nil
      elsif bytes_field && (match = line.match(/\s\.+:\s*([0-9A-Fa-f]+)\s*$/))
        fields[bytes_field] += match[1]
      end
    end
    raise E2E::CommissioningError.new("Missing reverse commissioning response") unless in_response

    timeout = fields["commissioningTimeout"]?.try(&.to_u16?)
    verifier = fields["PAKEPasscodeVerifier"]?
    discriminator = fields["discriminator"]?.try(&.to_u16?)
    iterations = fields["iterations"]?.try(&.to_u32?)
    salt = fields["salt"]?
    unless timeout && verifier && discriminator && iterations && salt &&
           verifier.size == Matter::Commissioning::WindowService::PAKE_PASSCODE_VERIFIER_LENGTH * 2 &&
           (32..64).includes?(salt.size) && salt.size.even?
      raise E2E::CommissioningError.new("Incomplete reverse commissioning response fields")
    end
    Window.new(timeout, verifier, discriminator, iterations, salt)
  end

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

describe ReverseCommissioningCrystalE2E do
  it "reassembles wrapped chip-tool verifier and salt bytes" do
    verifier = "AB" * 97
    salt = "CD" * 32
    output = <<-LOG
      [TOO]   ReverseOpenCommissioningWindow: {
      [TOO]     commissioningTimeout: 180
      [TOO]     PAKEPasscodeVerifier: #{verifier[0, 80]}
      [TOO]     ....................: #{verifier[80, 80]}
      [TOO]     ....................: #{verifier[160, 34]}
      [TOO]     discriminator: 3840
      [TOO]     iterations: 1000
      [TOO]     salt: #{salt[0, 40]}
      [TOO]     ....: #{salt[40, 24]}
      [TOO]   }
      LOG
    parsed = ReverseCommissioningCrystalE2E.parse_window(output)
    parsed.commissioning_timeout.should eq(180_u16)
    parsed.verifier_hex.should eq(verifier)
    parsed.discriminator.should eq(3840_u16)
    parsed.iterations.should eq(1000_u32)
    parsed.salt_hex.should eq(salt)
  end

  it "rejects a response missing wire verifier bytes" do
    expect_raises(E2E::CommissioningError, /Incomplete reverse commissioning response/) do
      ReverseCommissioningCrystalE2E.parse_window(
        "ReverseOpenCommissioningWindow: {\ncommissioningTimeout: 180\ndiscriminator: 3840\niterations: 1000\nsalt: #{"CD" * 16}\n}")
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
    wire = ReverseCommissioningCrystalE2E.parse_window(response.output)
    sidecar = JSON.parse(File.read(ReverseCommissioningCrystalE2E::WINDOW_PATH))
    wire.commissioning_timeout.to_i64.should eq(sidecar["commissioning_timeout"].as_i64)
    wire.verifier_hex.upcase.should eq(sidecar["verifier"].as_s.upcase)
    wire.discriminator.to_i64.should eq(sidecar["discriminator"].as_i64)
    wire.iterations.to_i64.should eq(sidecar["iterations"].as_i64)
    wire.salt_hex.upcase.should eq(sidecar["salt"].as_s.upcase)

    expect_success(target.chip(["administratorcommissioning", "open-commissioning-window",
                                wire.commissioning_timeout.to_s,
                                "hex:#{wire.verifier_hex}",
                                wire.discriminator.to_s,
                                wire.iterations.to_s,
                                "hex:#{wire.salt_hex}",
                                target.node, "0", "--timedInteractionTimeoutMs", "10000"]))

    ReverseCommissioningCrystalE2E.wait_for_completion(host)
    state = Matter::Controller::StateStore.new(
      Matter::Storage::YamlFile.new(ReverseCommissioningCrystalE2E::CONTROLLER_PATH)).load
    state.nodes.has_key?(ReverseCommissioningCrystalE2E::SOURCE_TARGET_ID).should be_true
    fabrics = expect_success(target.read("operationalcredentials", "commissioned-fabrics", 0))
    fabrics.int("CommissionedFabrics").should eq(2_i64), fabrics.output
  end
end
