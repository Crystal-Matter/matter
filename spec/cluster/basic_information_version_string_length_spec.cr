require "../spec_helper"
require "../../src/matter/cluster/basic_information"

describe "Basic Information version string lengths" do
  it "accepts 1 and 64 UTF-8 bytes for both version strings on construction and wire reads" do
    label = "é" * 32
    label.bytesize.should eq(Matter::Cluster::BasicInformation::VERSION_STRING_MAX_BYTES)

    cluster = build(Matter::Cluster::BasicInformation, 0,
      hardware_version_string: "x", software_version_string: label)
    read(cluster, Matter::Cluster::BasicInformation::ATTR_HARDWARE_VERSION_STRING).should eq("x")
    read(cluster, Matter::Cluster::BasicInformation::ATTR_SOFTWARE_VERSION_STRING).should eq(label)

    other = build(Matter::Cluster::BasicInformation, 0,
      hardware_version_string: label, software_version_string: "x")
    read(other, Matter::Cluster::BasicInformation::ATTR_HARDWARE_VERSION_STRING).should eq(label)
    read(other, Matter::Cluster::BasicInformation::ATTR_SOFTWARE_VERSION_STRING).should eq("x")
  end

  it "rejects empty and oversized strings during construction" do
    oversized = "é" * 32 + "a"
    invalid_utf8 = String.new(Bytes[0xC3, 0x28])
    oversized.bytesize.should eq(Matter::Cluster::BasicInformation::VERSION_STRING_MAX_BYTES + 1)
    invalid_utf8.valid_encoding?.should be_false

    expect_raises(Matter::ConfigurationError) do
      build(Matter::Cluster::BasicInformation, 0, hardware_version_string: "")
    end
    expect_raises(Matter::ConfigurationError) do
      build(Matter::Cluster::BasicInformation, 0, software_version_string: "")
    end
    expect_raises(Matter::ConfigurationError) do
      build(Matter::Cluster::BasicInformation, 0, hardware_version_string: oversized)
    end
    expect_raises(Matter::ConfigurationError) do
      build(Matter::Cluster::BasicInformation, 0, software_version_string: oversized)
    end
    expect_raises(Matter::ConfigurationError) do
      build(Matter::Cluster::BasicInformation, 0, hardware_version_string: invalid_utf8)
    end
    expect_raises(Matter::ConfigurationError) do
      build(Matter::Cluster::BasicInformation, 0, software_version_string: invalid_utf8)
    end
  end

  it "rejects invalid host assignments without changing the wire value or data version" do
    cluster = build(Matter::Cluster::BasicInformation, 0)
    changed = [] of UInt32
    cluster.on_attribute_changed = ->(_endpoint : UInt16, _cluster : UInt32, attribute : UInt32) {
      changed << attribute
      nil
    }

    max_bytes = "é" * 32
    cluster.hardware_version_string = max_bytes
    cluster.software_version_string = "v"
    accepted_version = cluster.data_version
    accepted_changes = changed.dup

    expect_raises(Matter::ConfigurationError) { cluster.hardware_version_string = "" }
    expect_raises(Matter::ConfigurationError) { cluster.hardware_version_string = max_bytes + "a" }
    expect_raises(Matter::ConfigurationError) { cluster.software_version_string = "" }
    expect_raises(Matter::ConfigurationError) { cluster.software_version_string = max_bytes + "a" }
    invalid_utf8 = String.new(Bytes[0xC3, 0x28])
    expect_raises(Matter::ConfigurationError) { cluster.hardware_version_string = invalid_utf8 }
    expect_raises(Matter::ConfigurationError) { cluster.software_version_string = invalid_utf8 }

    cluster.data_version.should eq(accepted_version)
    changed.should eq(accepted_changes)
    read(cluster, Matter::Cluster::BasicInformation::ATTR_HARDWARE_VERSION_STRING).should eq(max_bytes)
    read(cluster, Matter::Cluster::BasicInformation::ATTR_SOFTWARE_VERSION_STRING).should eq("v")
  end
end
