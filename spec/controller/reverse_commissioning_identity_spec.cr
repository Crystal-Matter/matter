require "../spec_helper"
require "../../src/matter/controller"

private class ReverseIdentityCommissioner < Matter::Controller::Commissioning::Commissioner
  def check_expected(expected : Tuple(UInt16, UInt16)?, vendor_id : UInt16, product_id : UInt16) : Nil
    verify_expected_identity!(expected, vendor_id, product_id)
  end
end

describe "reverse commissioning attested target identity" do
  it "accepts the approved VID/PID and rejects a substituted attested target" do
    commissioner = ReverseIdentityCommissioner.new(
      Matter::Controller::StateStore.new(Matter::Storage::Memory.new))
    expected = {0xFFF1_u16, 0x1234_u16}
    commissioner.check_expected(expected, 0xFFF1_u16, 0x1234_u16)
    expect_raises(Matter::AuthenticationError, /VendorID/) do
      commissioner.check_expected(expected, 0xFFF2_u16, 0x1234_u16)
    end
    expect_raises(Matter::AuthenticationError, /ProductID/) do
      commissioner.check_expected(expected, 0xFFF1_u16, 0x1235_u16)
    end
    commissioner.close
  end
end
