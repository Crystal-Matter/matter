require "../spec_helper"
require "../../src/matter/cluster/cluster"
require "../../src/matter/cluster/on_off"
require "../../src/matter/interaction_model/paths"
require "../../src/matter/protocol/message_handler"

# Avoid binding OS UDP sockets in the spec environment.
class NoSocketTransportForSubscriptionNotificationSpec < Matter::Transport::UDPTransport
  def self.new_for_spec : self
    transport = allocate
    transport.initialize_for_spec
    transport
  end

  protected def initialize_for_spec : Nil
    @port = 0
    @on_message = nil
    initialize_reliable_messages
  end

  def start : Nil
  end

  def stop : Nil
  end

  def close : Nil
  end

  def send_raw(data : Bytes | Slice(UInt8), peer_address : Socket::IPAddress) : Nil
  end
end

describe "Subscription Notifications" do
  describe Matter::Cluster::Base do
    describe "#on_attribute_changed callback" do
      it "can set and retrieve the callback" do
        endpoint = endpoint(1)
        cluster = Matter::Cluster::OnOff.new(endpoint)

        callback_called = false
        cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, _attr : UInt32) {
          callback_called = true
        }

        cluster.on_attribute_changed.should_not be_nil
      end

      it "callback is nil by default" do
        endpoint = endpoint(1)
        cluster = Matter::Cluster::OnOff.new(endpoint)

        cluster.on_attribute_changed.should be_nil
      end
    end
  end

  describe Matter::Cluster::OnOff do
    describe "attribute change notifications" do
      it "notifies when on_off state changes via On command" do
        endpoint = endpoint(1)
        cluster = Matter::Cluster::OnOff.new(endpoint, on_off: false)

        notification_received = false
        notified_endpoint : UInt16 = 0_u16
        notified_cluster : UInt32 = 0_u32
        notified_attribute : UInt32 = 0_u32

        cluster.on_attribute_changed = ->(ep : UInt16, cl : UInt32, attr : UInt32) {
          notification_received = true
          notified_endpoint = ep
          notified_cluster = cl
          notified_attribute = attr
        }

        invoke(cluster, Matter::Cluster::OnOff::CMD_ON)

        notification_received.should be_true
        notified_endpoint.should eq(1_u16)
        notified_cluster.should eq(Matter::Cluster::OnOff::CLUSTER_ID)
        notified_attribute.should eq(Matter::Cluster::OnOff::ATTR_ON_OFF)
      end

      it "notifies when on_off state changes via Off command" do
        endpoint = endpoint(1)
        cluster = Matter::Cluster::OnOff.new(endpoint, on_off: true)

        notification_received = false
        notified_attribute : UInt32 = 0_u32

        cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, attr : UInt32) {
          notification_received = true
          notified_attribute = attr
        }

        invoke(cluster, Matter::Cluster::OnOff::CMD_OFF)

        notification_received.should be_true
        notified_attribute.should eq(Matter::Cluster::OnOff::ATTR_ON_OFF)
      end

      it "notifies when on_off state changes via Toggle command" do
        endpoint = endpoint(1)
        cluster = Matter::Cluster::OnOff.new(endpoint, on_off: false)

        notification_count = 0

        cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, _attr : UInt32) {
          notification_count += 1
        }

        # Toggle off -> on
        invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE)
        notification_count.should eq(1)

        # Toggle on -> off
        invoke(cluster, Matter::Cluster::OnOff::CMD_TOGGLE)
        notification_count.should eq(2)
      end

      it "does not notify when state doesn't change" do
        endpoint = endpoint(1)
        cluster = Matter::Cluster::OnOff.new(endpoint, on_off: false)

        notification_count = 0

        cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, _attr : UInt32) {
          notification_count += 1
        }

        # Off command when already off - should not notify
        invoke(cluster, Matter::Cluster::OnOff::CMD_OFF)
        notification_count.should eq(0)
      end

      it "increments data_version when notifying" do
        endpoint = endpoint(1)
        cluster = Matter::Cluster::OnOff.new(endpoint, on_off: false)

        initial_version = cluster.data_version

        invoke(cluster, Matter::Cluster::OnOff::CMD_ON)

        cluster.data_version.should eq(initial_version + 1)
      end

      it "calls both on_attribute_changed and on_state_changed callbacks" do
        endpoint = endpoint(1)
        cluster = Matter::Cluster::OnOff.new(endpoint, on_off: false)

        attribute_callback_called = false
        state_callback_called = false
        state_value : Bool? = nil

        cluster.on_attribute_changed = ->(_ep : UInt16, _cl : UInt32, _attr : UInt32) {
          attribute_callback_called = true
        }

        cluster.on_state_changed do |new_state|
          state_callback_called = true
          state_value = new_state
        end

        invoke(cluster, Matter::Cluster::OnOff::CMD_ON)

        attribute_callback_called.should be_true
        state_callback_called.should be_true
        state_value.should be_true
      end
    end
  end

  describe Matter::Protocol::ActiveSubscription do
    describe "#matches?" do
      it "matches exact path" do
        session = create_mock_session
        paths = [Matter::InteractionModel::AttributePath.new(
          endpoint: 1_u16,
          cluster: 0x0006_u32,
          attribute: 0x0000_u32
        )]

        subscription = Matter::Protocol::ActiveSubscription.new(
          subscription_id: 1_u32,
          min_interval: 0_u16,
          max_interval: 60_u16,
          peer: Socket::IPAddress.new("127.0.0.1", 5540),
          session: session,
          attribute_paths: paths,
          exchange_id: 1000_u16
        )

        # Exact match
        subscription.matches?(1_u16, 0x0006_u32, 0x0000_u32).should be_true

        # Different endpoint
        subscription.matches?(2_u16, 0x0006_u32, 0x0000_u32).should be_false

        # Different cluster
        subscription.matches?(1_u16, 0x0008_u32, 0x0000_u32).should be_false

        # Different attribute
        subscription.matches?(1_u16, 0x0006_u32, 0x0001_u32).should be_false
      end

      it "matches wildcard endpoint" do
        session = create_mock_session
        paths = [Matter::InteractionModel::AttributePath.new(
          endpoint: nil, # Wildcard
          cluster: 0x0006_u32,
          attribute: 0x0000_u32
        )]

        subscription = Matter::Protocol::ActiveSubscription.new(
          subscription_id: 1_u32,
          min_interval: 0_u16,
          max_interval: 60_u16,
          peer: Socket::IPAddress.new("127.0.0.1", 5540),
          session: session,
          attribute_paths: paths,
          exchange_id: 1000_u16
        )

        # Any endpoint should match
        subscription.matches?(1_u16, 0x0006_u32, 0x0000_u32).should be_true
        subscription.matches?(2_u16, 0x0006_u32, 0x0000_u32).should be_true
        subscription.matches?(0_u16, 0x0006_u32, 0x0000_u32).should be_true

        # But cluster and attribute must still match
        subscription.matches?(1_u16, 0x0008_u32, 0x0000_u32).should be_false
      end

      it "matches wildcard cluster" do
        session = create_mock_session
        paths = [Matter::InteractionModel::AttributePath.new(
          endpoint: 1_u16,
          cluster: nil, # Wildcard
          attribute: 0x0000_u32
        )]

        subscription = Matter::Protocol::ActiveSubscription.new(
          subscription_id: 1_u32,
          min_interval: 0_u16,
          max_interval: 60_u16,
          peer: Socket::IPAddress.new("127.0.0.1", 5540),
          session: session,
          attribute_paths: paths,
          exchange_id: 1000_u16
        )

        # Any cluster should match
        subscription.matches?(1_u16, 0x0006_u32, 0x0000_u32).should be_true
        subscription.matches?(1_u16, 0x0008_u32, 0x0000_u32).should be_true

        # But endpoint and attribute must still match
        subscription.matches?(2_u16, 0x0006_u32, 0x0000_u32).should be_false
      end

      it "matches wildcard attribute" do
        session = create_mock_session
        paths = [Matter::InteractionModel::AttributePath.new(
          endpoint: 1_u16,
          cluster: 0x0006_u32,
          attribute: nil # Wildcard
        )]

        subscription = Matter::Protocol::ActiveSubscription.new(
          subscription_id: 1_u32,
          min_interval: 0_u16,
          max_interval: 60_u16,
          peer: Socket::IPAddress.new("127.0.0.1", 5540),
          session: session,
          attribute_paths: paths,
          exchange_id: 1000_u16
        )

        # Any attribute should match
        subscription.matches?(1_u16, 0x0006_u32, 0x0000_u32).should be_true
        subscription.matches?(1_u16, 0x0006_u32, 0x0001_u32).should be_true
        subscription.matches?(1_u16, 0x0006_u32, 0xFFFF_u32).should be_true

        # But endpoint and cluster must still match
        subscription.matches?(1_u16, 0x0008_u32, 0x0000_u32).should be_false
      end

      it "matches full wildcard path" do
        session = create_mock_session
        paths = [Matter::InteractionModel::AttributePath.new(
          endpoint: nil,
          cluster: nil,
          attribute: nil
        )]

        subscription = Matter::Protocol::ActiveSubscription.new(
          subscription_id: 1_u32,
          min_interval: 0_u16,
          max_interval: 60_u16,
          peer: Socket::IPAddress.new("127.0.0.1", 5540),
          session: session,
          attribute_paths: paths,
          exchange_id: 1000_u16
        )

        # Everything should match
        subscription.matches?(0_u16, 0x0000_u32, 0x0000_u32).should be_true
        subscription.matches?(1_u16, 0x0006_u32, 0x0000_u32).should be_true
        subscription.matches?(255_u16, 0xFFFF_u32, 0xFFFF_u32).should be_true
      end

      it "matches any of multiple paths" do
        session = create_mock_session
        paths = [
          Matter::InteractionModel::AttributePath.new(
            endpoint: 1_u16,
            cluster: 0x0006_u32,
            attribute: 0x0000_u32
          ),
          Matter::InteractionModel::AttributePath.new(
            endpoint: 1_u16,
            cluster: 0x0008_u32,
            attribute: 0x0000_u32
          ),
        ]

        subscription = Matter::Protocol::ActiveSubscription.new(
          subscription_id: 1_u32,
          min_interval: 0_u16,
          max_interval: 60_u16,
          peer: Socket::IPAddress.new("127.0.0.1", 5540),
          session: session,
          attribute_paths: paths,
          exchange_id: 1000_u16
        )

        # Matches first path
        subscription.matches?(1_u16, 0x0006_u32, 0x0000_u32).should be_true

        # Matches second path
        subscription.matches?(1_u16, 0x0008_u32, 0x0000_u32).should be_true

        # Doesn't match either
        subscription.matches?(1_u16, 0x000A_u32, 0x0000_u32).should be_false
      end
    end

    describe "#exchange_id" do
      it "stores the exchange_id from creation" do
        session = create_mock_session
        subscription = Matter::Protocol::ActiveSubscription.new(
          subscription_id: 1_u32,
          min_interval: 0_u16,
          max_interval: 60_u16,
          peer: Socket::IPAddress.new("127.0.0.1", 5540),
          session: session,
          attribute_paths: [] of Matter::InteractionModel::AttributePath,
          exchange_id: 12345_u16
        )

        subscription.exchange_id.should eq(12345_u16)
      end
    end

    describe "#last_report_time" do
      it "is set to current time on creation" do
        session = create_mock_session
        before = Time.utc

        subscription = Matter::Protocol::ActiveSubscription.new(
          subscription_id: 1_u32,
          min_interval: 0_u16,
          max_interval: 60_u16,
          peer: Socket::IPAddress.new("127.0.0.1", 5540),
          session: session,
          attribute_paths: [] of Matter::InteractionModel::AttributePath,
          exchange_id: 1000_u16
        )

        after = Time.utc

        subscription.last_report_time.should be >= before
        subscription.last_report_time.should be <= after
      end
    end
  end

  describe Matter::Protocol::MessageHandler do
    describe "#setup_cluster_notifications" do
      it "wires up on_attribute_changed callback for all clusters" do
        transport = NoSocketTransportForSubscriptionNotificationSpec.new_for_spec
        storage = Matter::Storage::Memory.new
        fabric_table = Matter::FabricTable.new(storage)

        handler = Matter::Protocol::MessageHandler.new(
          transport: transport,
          setup_pin: 20202021_u32,
          discriminator: 3840_u16,
          fabric_table: fabric_table
        )

        # Add a test cluster
        endpoint = endpoint(1)
        on_off = Matter::Cluster::OnOff.new(endpoint)
        handler.clusters[{1_u16, Matter::Cluster::OnOff::CLUSTER_ID}] = on_off

        # Initially callback should be nil
        on_off.on_attribute_changed.should be_nil

        # Setup notifications
        handler.setup_cluster_notifications

        # Now callback should be set
        on_off.on_attribute_changed.should_not be_nil
      end
    end
  end
end

# Helper to create a mock SecureContext for testing
def create_mock_session : Matter::Session::SecureContext
  Matter::Session::SecureContext.new(
    session_id: 1_u16,
    peer_session_id: 2_u16,
    session_type: Matter::Session::SessionType::Unicast,
    encryption_key: Bytes.new(16),
    decryption_key: Bytes.new(16),
    initiator: false,
    case_session: true,
    fabric_index: 1_u8
  )
end
