require "../spec_helper"
require "../../src/matter/protocol/icd/check_in_message"

describe Matter::Protocol::Icd::CheckInMessage do
  # Official connectedhomeip v1.6.0.0
  # src/protocols/secure_channel/tests/CheckIn_Message_test_vectors.h, vector 2.
  key = "18fdbceaef01955b0ec875eda3ae6ee8".hexbytes
  payload = ("9b02ed21ee0c7b491985502e37" +
             "2dbd7b3f8b4f8e3c" +
             "5ad99419389f41a8d609938c67a86d65").hexbytes

  it "matches the independent Matter 1.6 SDK Check-In vector" do
    encoded = Matter::Protocol::Icd::CheckInMessage.encode(key, 15_u32, "This".to_slice)
    encoded.should eq(payload)
    decoded = Matter::Protocol::Icd::CheckInMessage.decode(key, payload)
    decoded.counter.should eq(15_u32)
    decoded.application_data.should eq("This".to_slice)
  end

  it "rejects a modified nonce, ciphertext, and wrong key" do
    tampered_nonce = payload.dup
    tampered_nonce[0] ^= 0xff_u8
    expect_raises(Matter::CodecError) { Matter::Protocol::Icd::CheckInMessage.decode(key, tampered_nonce) }

    tampered_mic = payload.dup
    tampered_mic[-1] ^= 0xff_u8
    expect_raises(Matter::CodecError) { Matter::Protocol::Icd::CheckInMessage.decode(key, tampered_mic) }

    expect_raises(Matter::CodecError) do
      Matter::Protocol::Icd::CheckInMessage.decode(Bytes.new(16, 0_u8), payload)
    end
  end

  it "encodes the ICD ActiveModeThreshold in little endian" do
    encoded = Matter::Protocol::Icd::CheckInMessage.encode_icd(key, 42_u32, 5_000_u16)
    decoded = Matter::Protocol::Icd::CheckInMessage.decode(key, encoded)
    decoded.counter.should eq(42_u32)
    decoded.application_data.should eq(Bytes[0x88_u8, 0x13_u8])
  end
end
