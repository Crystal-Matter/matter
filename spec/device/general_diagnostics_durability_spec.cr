require "../spec_helper"
require "../../src/matter/device"
require "../../src/matter/storage/sqlite"

private class DurableDiagnosticsDevice < Matter::Device
  identity vendor: "Crystal Matter", product: "Diagnostics Durability Test",
    vendor_id: 0xFFF1_u16, product_id: 0x8130_u16,
    discriminator: 3850_u16, pin: 20202098_u32,
    device_type: Matter::DeviceType::ROOT_NODE

  storage :memory

  def diagnostics : Matter::Cluster::GeneralDiagnostics
    node.get_cluster(Matter::Node::ROOT_ENDPOINT_ID,
      Matter::Cluster::GeneralDiagnostics).as(Matter::Cluster::GeneralDiagnostics)
  end

  def release : Nil
    message_handler.close
    persistence.close
    transport.close
  end
end

private class DurableDiagnosticsDmtestDevice < DurableDiagnosticsDevice
  protected def general_diagnostics_test_enable_key : Bytes?
    Bytes.new(16, 1_u8)
  end
end

private class FailingDiagnosticsYaml < Matter::Storage::YamlFile
  def write(collection : String, id : String, document : Matter::Storage::Document) : Nil
    if collection == Matter::Storage::Collections::DEVICE && id == "identity" &&
       document["reboot_count"]? == 1_i64
      raise IO::Error.new("simulated diagnostics write failure")
    end
    super
  end
end

describe "General Diagnostics durability" do
  it "reports a nonvolatile RebootCount across YAML restarts" do
    directory = File.join(Dir.tempdir, "matter-diagnostics-yaml-#{Random::Secure.hex(6)}")
    path = File.join(directory, "state.yml")
    counts = [] of UInt16
    3.times do
      device = DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
      counts << device.diagnostics.reboot_count
      device.release
    end
    counts.should eq([0_u16, 1_u16, 2_u16])
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "reports a nonvolatile RebootCount across SQLite restarts" do
    directory = File.join(Dir.tempdir, "matter-diagnostics-sqlite-#{Random::Secure.hex(6)}")
    path = File.join(directory, "state.sqlite3")
    counts = [] of UInt16
    3.times do
      device = DurableDiagnosticsDevice.new(storage: Matter::Storage::Sqlite.new(path), port: 0)
      counts << device.diagnostics.reboot_count
      device.release
    end
    counts.should eq([0_u16, 1_u16, 2_u16])
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "saturates RebootCount instead of resetting to zero at the wire maximum" do
    directory = File.join(Dir.tempdir, "matter-diagnostics-max-#{Random::Secure.hex(6)}")
    path = File.join(directory, "state.yml")
    first = DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.release

    backend = Matter::Storage::YamlFile.new(path).tap(&.open)
    identity = backend.read(Matter::Storage::Collections::DEVICE, "identity").as(Matter::Storage::Document)
    identity["reboot_count"] = UInt16::MAX.to_i64
    backend.write(Matter::Storage::Collections::DEVICE, "identity", identity)
    backend.close

    second = DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.diagnostics.reboot_count.should eq(UInt16::MAX)
    second.release
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "keeps RebootCount when the optional DMTEST FeatureMap changes" do
    directory = File.join(Dir.tempdir, "matter-diagnostics-feature-#{Random::Secure.hex(6)}")
    path = File.join(directory, "state.yml")
    first = DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.release

    second = DurableDiagnosticsDmtestDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    second.diagnostics.feature_map.data_model_test?.should be_true
    second.diagnostics.reboot_count.should eq(1_u16)
    second.release

    third = DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    third.diagnostics.reboot_count.should eq(2_u16)
    third.release
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "rejects a corrupt persisted RebootCount rather than resetting it" do
    directory = File.join(Dir.tempdir, "matter-diagnostics-corrupt-#{Random::Secure.hex(6)}")
    path = File.join(directory, "state.yml")
    first = DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.release

    backend = Matter::Storage::YamlFile.new(path).tap(&.open)
    identity = backend.read(Matter::Storage::Collections::DEVICE, "identity").as(Matter::Storage::Document)
    identity["reboot_count"] = "invalid"
    backend.write(Matter::Storage::Collections::DEVICE, "identity", identity)
    backend.close

    expect_raises(Matter::StorageError, /Invalid persisted General Diagnostics RebootCount/) do
      DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    end
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "rejects a missing counter from an initialized identity" do
    directory = File.join(Dir.tempdir, "matter-diagnostics-missing-#{Random::Secure.hex(6)}")
    path = File.join(directory, "state.yml")
    first = DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.release

    backend = Matter::Storage::YamlFile.new(path).tap(&.open)
    identity = backend.read(Matter::Storage::Collections::DEVICE, "identity").as(Matter::Storage::Document)
    identity.delete("reboot_count")
    backend.write(Matter::Storage::Collections::DEVICE, "identity", identity)
    backend.close

    expect_raises(Matter::StorageError, /Missing persisted General Diagnostics RebootCount/) do
      DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    end
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "fails startup when the updated RebootCount cannot be saved" do
    directory = File.join(Dir.tempdir, "matter-diagnostics-failure-#{Random::Secure.hex(6)}")
    path = File.join(directory, "state.yml")
    first = DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    first.release

    backend = FailingDiagnosticsYaml.new(path)
    expect_raises(Matter::StorageError, /RebootCount/) do
      DurableDiagnosticsDevice.new(storage: backend, port: 0)
    end
    backend.close

    retry_device = DurableDiagnosticsDevice.new(storage: Matter::Storage::YamlFile.new(path), port: 0)
    retry_device.diagnostics.reboot_count.should eq(1_u16)
    retry_device.release
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "does not advertise TotalOperationalHours until it has a durable lifetime counter" do
    cluster = build(Matter::Cluster::GeneralDiagnostics, 0)
    cluster.attributes.map(&.id.id).should_not contain(0x0003_u32)
  end
end
