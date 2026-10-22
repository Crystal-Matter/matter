require "../spec_helper"
require "../support/operational_credentials_helpers"

module Matter
  class FakeResponder
    include MDNS::ResponderInterface

    getter stop_commissioning_calls = 0
    getter stop_operational_calls = 0
    getter advertise_commissioning_calls = 0
    getter advertise_operational_calls = 0
    getter advertised_operational_nodes = [] of UInt64

    def stop_commissioning : Nil
      @stop_commissioning_calls += 1
    end

    def advertise_commissioning(info : MDNS::CommissioningInfo, port : Int32 = 5540, ttl : Time::Span = 120.seconds) : Nil
      @advertise_commissioning_calls += 1
    end

    def advertise_operational(info : MDNS::OperationalInfo, port : Int32 = 5540, ttl : Time::Span = 120.seconds) : Nil
      @advertise_operational_calls += 1
      @advertised_operational_nodes << info.node_id
    end

    def stop_operational_advertisement : Nil
      @stop_operational_calls += 1
    end
  end

  # A registry that records the sessions the lifecycle manager deletes.
  class RecordingRegistry < Protocol::SessionRegistry
    getter deleted : Array(UInt16) = [] of UInt16

    def self.new_for_spec : self
      new(mrp_cache: Protocol::MrpCache.new(Matter::Spec::CaptureTransport.new_for_spec))
    end

    def delete_session(session_id : UInt16) : Bool
      @deleted << session_id
      super
    end
  end
end

describe Matter::Device::LifecycleManager do
  it "refreshes operational discovery and retires old CASE sessions when a NOC identity changes" do
    table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    fabric = OpCredsTestHelpers.create_test_fabric(0x1111_u64, 1_u8)
    table.add_fabric(fabric).should be_true
    registry = Matter::RecordingRegistry.new_for_spec
    registry.sessions[22282_u16] = Matter::Session::SecureContext.new(
      session_id: 22282_u16, peer_session_id: 40019_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16), decryption_key: Bytes.new(16),
      initiator: false, case_session: true, fabric_index: 1_u8)
    advertiser = Matter::FakeResponder.new
    opcreds = Matter::Cluster::OperationalCredentials.new(table)
    Matter::Device::LifecycleManager.new(
      fabric_table: table, registry: registry, operational_credentials: opcreds,
      responder: advertiser,
      commissioning_info: -> {
        Matter::MDNS::CommissioningInfo.new("test", 0xFFF1_u16, 0x8000_u16,
          3840_u16, 0_u32, Matter::MDNS::CommissioningMode::Basic)
      },
      fabric_session_cleanup_delay: Time::Span.zero)

    fabric.node_id = 0x7777_u64
    table.update_fabric(fabric).should be_true
    opcreds.on_fabric_updated.as(Proc(Matter::Fabric, Nil)).call(fabric)

    registry.deleted.should contain(22282_u16)
    advertiser.stop_operational_calls.should be >= 1
    advertiser.advertised_operational_nodes.last.should eq(0x7777_u64)
  end

  it "defers CASE session cleanup on fabric removal" do
    storage = Matter::Storage::Memory.new
    fabric_table = Matter::FabricTable.new(storage)

    registry = Matter::RecordingRegistry.new_for_spec
    registry.sessions[22282_u16] = Matter::Session::SecureContext.new(
      session_id: 22282_u16,
      peer_session_id: 40019_u16,
      session_type: Matter::Session::SessionType::Unicast,
      encryption_key: Bytes.new(16, 0_u8),
      decryption_key: Bytes.new(16, 0_u8),
      initiator: false,
      case_session: true,
      fabric_index: 1_u8
    )

    advertiser = Matter::FakeResponder.new
    opcreds = Matter::Cluster::OperationalCredentials.new(fabric_table)

    Matter::Device::LifecycleManager.new(
      fabric_table: fabric_table,
      registry: registry,
      operational_credentials: opcreds,
      responder: advertiser,
      commissioning_info: -> {
        Matter::MDNS::CommissioningInfo.new(
          device_name: "test",
          vendor_id: 0xFFF1_u16,
          product_id: 0x8000_u16,
          discriminator: 3840_u16,
          device_type: 0_u32,
          commissioning_mode: Matter::MDNS::CommissioningMode::Basic
        )
      },
      fabric_session_cleanup_delay: 200.milliseconds
    )

    opcreds.on_fabric_removed.as(Proc(UInt8, Nil)).call(1_u8)

    registry.sessions.has_key?(22282_u16).should be_true
    sleep 50.milliseconds
    registry.sessions.has_key?(22282_u16).should be_true

    sleep 300.milliseconds
    registry.sessions.has_key?(22282_u16).should be_false
    registry.deleted.should contain(22282_u16)

    # Ensure mDNS switches were invoked (fabric table is empty, so commissioning should be advertised)
    advertiser.advertise_commissioning_calls.should be >= 1
  end
end
