require "../spec_helper"
require "openssl"
require "../../src/matter/protocol/ota_image"

private struct OtaHeaderFixture
  include TLV::Serializable

  @[TLV::Field(tag: 0)]
  property vendor_id : UInt16

  @[TLV::Field(tag: 1)]
  property product_id : UInt16

  @[TLV::Field(tag: 2)]
  property software_version : UInt32

  @[TLV::Field(tag: 3)]
  property software_version_string : String

  @[TLV::Field(tag: 4)]
  property payload_size : UInt64

  @[TLV::Field(tag: 5, optional: true)]
  property min_applicable_software_version : UInt32?

  @[TLV::Field(tag: 6, optional: true)]
  property max_applicable_software_version : UInt32?

  @[TLV::Field(tag: 8)]
  property image_digest_type : UInt8

  @[TLV::Field(tag: 9)]
  property image_digest : Bytes

  def initialize(@vendor_id : UInt16, @product_id : UInt16,
                 @software_version : UInt32, @software_version_string : String,
                 @payload_size : UInt64, @image_digest_type : UInt8,
                 @image_digest : Bytes,
                 @min_applicable_software_version : UInt32? = nil,
                 @max_applicable_software_version : UInt32? = nil)
  end
end

private def ota_image_fixture(payload : Bytes = Bytes.new(4097) { |index| (index % 251).to_u8 },
                              software_version : UInt32 = 11_u32,
                              vendor_id : UInt16 = 0xFFF1_u16,
                              product_id : UInt16 = 0x8001_u16,
                              min_version : UInt32? = nil,
                              max_version : UInt32? = nil,
                              digest_type : UInt8 = 1_u8) : Bytes
  algorithm = digest_type == 10_u8 ? "SHA3-256" : "SHA256"
  digest = OpenSSL::Digest.new(algorithm).update(payload).final
  header = OtaHeaderFixture.new(vendor_id, product_id, software_version,
    "11.0", payload.size.to_u64, digest_type, digest, min_version, max_version).to_slice
  image = IO::Memory.new
  image.write_bytes(0x1BEEF11E_u32, IO::ByteFormat::LittleEndian)
  image.write_bytes((16 + header.size + payload.size).to_u64, IO::ByteFormat::LittleEndian)
  image.write_bytes(header.size.to_u32, IO::ByteFormat::LittleEndian)
  image.write(header)
  image.write(payload)
  image.to_slice
end

describe Matter::Protocol::OtaImage do
  it "validates a streamed Matter image and its payload SHA-256 digest" do
    image = ota_image_fixture
    header = Matter::Protocol::OtaImage.validate(IO::Memory.new(image),
      vendor_id: 0xFFF1_u16, product_id: 0x8001_u16,
      current_version: 10_u32, offered_version: 11_u32)
    header.software_version.should eq(11_u32)
    header.payload_size.should eq(4097_u64)
  end

  it "validates a SHA3-256 image digest advertised by the OTA header" do
    Matter::Protocol::OtaImage.validate(IO::Memory.new(ota_image_fixture(digest_type: 10_u8)),
      vendor_id: 0xFFF1_u16, product_id: 0x8001_u16,
      current_version: 10_u32, offered_version: 11_u32)
  end

  it "rejects payload changes and extra bytes even when the header is valid" do
    image = ota_image_fixture.dup
    image[-1] ^= 0x01_u8
    expect_raises(Matter::Protocol::OtaImage::InvalidImage) do
      Matter::Protocol::OtaImage.validate(IO::Memory.new(image),
        vendor_id: 0xFFF1_u16, product_id: 0x8001_u16,
        current_version: 10_u32, offered_version: 11_u32)
    end

    extra = ota_image_fixture + Bytes[0x00]
    expect_raises(Matter::Protocol::OtaImage::InvalidImage) do
      Matter::Protocol::OtaImage.validate(IO::Memory.new(extra),
        vendor_id: 0xFFF1_u16, product_id: 0x8001_u16,
        current_version: 10_u32, offered_version: 11_u32)
    end
  end

  it "rejects an image for the wrong product or offered version" do
    image = ota_image_fixture
    expect_raises(Matter::Protocol::OtaImage::InvalidImage) do
      Matter::Protocol::OtaImage.validate(IO::Memory.new(image),
        vendor_id: 0xFFF1_u16, product_id: 0x8002_u16,
        current_version: 10_u32, offered_version: 11_u32)
    end
    expect_raises(Matter::Protocol::OtaImage::InvalidImage) do
      Matter::Protocol::OtaImage.validate(IO::Memory.new(image),
        vendor_id: 0xFFF1_u16, product_id: 0x8001_u16,
        current_version: 10_u32, offered_version: 12_u32)
    end
  end

  it "accepts wildcard VID/PID and inclusive applicability bounds" do
    image = ota_image_fixture(vendor_id: 0_u16, product_id: 0_u16,
      min_version: 10_u32, max_version: 10_u32)
    Matter::Protocol::OtaImage.validate(IO::Memory.new(image),
      vendor_id: 0xFFF1_u16, product_id: 0x8001_u16,
      current_version: 10_u32, offered_version: 11_u32).software_version
      .should eq(11_u32)

    too_new = ota_image_fixture(min_version: 11_u32)
    expect_raises(Matter::Protocol::OtaImage::InvalidImage) do
      Matter::Protocol::OtaImage.validate(IO::Memory.new(too_new),
        vendor_id: 0xFFF1_u16, product_id: 0x8001_u16,
        current_version: 10_u32, offered_version: 11_u32)
    end
  end

  it "rejects truncated images and sizes outside the configured bound" do
    image = ota_image_fixture
    expect_raises(Matter::Protocol::OtaImage::InvalidImage) do
      Matter::Protocol::OtaImage.validate(IO::Memory.new(image[0, image.size - 1]),
        vendor_id: 0xFFF1_u16, product_id: 0x8001_u16,
        current_version: 10_u32, offered_version: 11_u32)
    end
    expect_raises(Matter::Protocol::OtaImage::InvalidImage) do
      Matter::Protocol::OtaImage.validate(IO::Memory.new(image),
        vendor_id: 0xFFF1_u16, product_id: 0x8001_u16,
        current_version: 10_u32, offered_version: 11_u32,
        max_total_bytes: (image.size - 1).to_u64)
    end
  end
end
