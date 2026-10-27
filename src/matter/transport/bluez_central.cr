require "../error"
require "../setup_payload"
require "./btp_central_handshake"

module Matter
  module Transport
    module Bluez
      SERVICE_UUID       = "0000fff6-0000-1000-8000-00805f9b34fb"
      C1_UUID            = "18ee2ef5-263d-4559-959f-4f9c429f9d11"
      C2_UUID            = "18ee2ef5-263d-4559-959f-4f9c429f9d12"
      SERVICE_DATA_SIZE  =    8
      SERVICE_DATA_TYPE  = 0_u8
      MAX_DISCRIMINATOR  = SetupPayload::MAX_DISCRIMINATOR
      SCAN_POLL_INTERVAL = 50.milliseconds

      record Device, path : String, address : String, service_data : Bytes
      record Service, path : String, uuid : String
      record Characteristic, path : String, uuid : String

      class RemoteError < Matter::TransportError
        getter remote_name : String?

        def initialize(message : String? = nil, cause : Exception? = nil, @remote_name : String? = nil)
          super(message, cause)
        end
      end

      abstract class Notifications
        abstract def mtu : Int32?
        abstract def read(timeout_span : Time::Span) : Bytes?
        abstract def close : Nil
      end

      # BlueZ operations are isolated here for a Linux GIO implementation and
      # deterministic tests. All paths are D-Bus object paths supplied by BlueZ.
      abstract class Bus
        abstract def start_scan(service_uuid : String) : Nil
        abstract def stop_scan : Nil
        abstract def devices : Array(Device)
        abstract def connect_device(path : String) : Nil
        abstract def services(device_path : String) : Array(Service)
        abstract def characteristics(service_path : String) : Array(Characteristic)
        abstract def write(characteristic_path : String, frame : Bytes) : Nil
        abstract def subscribe(characteristic_path : String) : Notifications
        abstract def disconnect_device(path : String) : Nil
      end

      class GattChannel < GattHandshakeChannel
        @notifications : Notifications?
        @closed = false

        def initialize(@bus : Bus, @device_path : String, @c1_path : String,
                       @c2_path : String)
        end

        def att_mtu : Int32?
          @notifications.try(&.mtu)
        end

        def write(frame : Bytes) : Nil
          raise Matter::TransportError.new("BlueZ GATT channel is closed") if @closed
          @bus.write(@c1_path, frame)
        end

        def subscribe : Nil
          raise Matter::TransportError.new("BlueZ GATT channel is closed") if @closed
          @notifications ||= @bus.subscribe(@c2_path)
        end

        def read(timeout_span : Time::Span) : Bytes?
          raise Matter::TransportError.new("BlueZ C2 indication subscription is not active") unless notifications = @notifications
          notifications.read(timeout_span)
        end

        def close : Nil
          return if @closed
          @closed = true
          begin
            @notifications.try(&.close)
          ensure
            @bus.disconnect_device(@device_path)
          end
        end

        def closed? : Bool
          @closed
        end
      end

      class Central
        def initialize(@bus : Bus)
        end

        def discover(discriminator : UInt16,
                     timeout_span : Time::Span = 30.seconds) : Device
          if discriminator > MAX_DISCRIMINATOR
            raise Matter::ConfigurationError.new("Matter BLE discriminator is out of range")
          end
          deadline = Time.instant + timeout_span
          @bus.start_scan(SERVICE_UUID)
          begin
            loop do
              if found = @bus.devices.find { |device| matches_discriminator?(device.service_data, discriminator) }
                return found
              end
              raise Matter::TimeoutError.new("Matter BLE advertisement not found") if Time.instant >= deadline
              sleep(SCAN_POLL_INTERVAL)
            end
          ensure
            @bus.stop_scan
          end
        end

        def open(device : Device,
                 timeout_span : Time::Span = 15.seconds) : BtpMessageTransport
          deadline = Time.instant + timeout_span
          channel = nil
          @bus.connect_device(device.path)
          loop do
            if service = @bus.services(device.path).find { |entry| entry.uuid.downcase == SERVICE_UUID }
              characteristics = @bus.characteristics(service.path)
              c1 = characteristics.find { |entry| entry.uuid.downcase == C1_UUID }
              c2 = characteristics.find { |entry| entry.uuid.downcase == C2_UUID }
              if c1 && c2
                channel = GattChannel.new(@bus, device.path, c1.path, c2.path)
                remaining = deadline - Time.instant
                raise Matter::TimeoutError.new("Matter BLE GATT discovery timed out") if remaining <= Time::Span.zero
                return BtpCentralHandshake.open(channel, timeout_span: remaining)
              end
            end
            raise Matter::TimeoutError.new("Matter BLE GATT discovery timed out") if Time.instant >= deadline
            sleep(SCAN_POLL_INTERVAL)
          end
        rescue ex
          channel.try(&.close)
          @bus.disconnect_device(device.path) unless channel
          raise ex
        end

        private def matches_discriminator?(service_data : Bytes, discriminator : UInt16) : Bool
          return false unless service_data.size == SERVICE_DATA_SIZE && service_data[0] == SERVICE_DATA_TYPE
          found = IO::ByteFormat::LittleEndian.decode(UInt16, service_data[1, 2])
          found <= MAX_DISCRIMINATOR && found == discriminator
        end
      end
    end
  end
end
