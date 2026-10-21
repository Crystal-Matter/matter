require "./cluster"
require "log"

module Matter
  module Cluster
    # General Diagnostics Cluster (0x0033)
    #
    # Provides general diagnostic information about the device.
    # Required on endpoint 0 for Root Node device type.
    #
    # Matter 1.6 § 11.11 - General Diagnostics Cluster
    class GeneralDiagnostics < Base
      Log = ::Log.for("matter.cluster.general_diagnostics")

      cluster 0x0033, revision: 2

      enum InterfaceType : UInt8
        # Indicates an interface of an unspecified type.
        Unspecified = 0

        # Indicates a Wi-Fi interface.
        WiFi = 1

        # Indicates a Ethernet interface.
        Ethernet = 2

        # Indicates a Cellular interface.
        Cellular = 3

        # Indicates a Thread interface.
        Thread = 4
      end

      enum BootReason : UInt8
        # The Node is unable to identify the Power-On reason as one of the other provided enumeration values.
        Unspecified = 0

        # The Node has booted as the result of physical interaction with the device resulting in a reboot.
        PowerOnReboot = 1

        # The Node has rebooted as the result of a brown-out of the Node’s power supply.
        BrownOutReset = 2

        # The Node has rebooted as the result of a software watchdog timer.
        SoftwareWatchdogReset = 3

        # The Node has rebooted as the result of a hardware watchdog timer.
        HardwareWatchdogReset = 4

        # The Node has rebooted as the result of a completed software update.
        SoftwareUpdateCompleted = 5

        # The Node has rebooted as the result of a software initiated reboot.
        SoftwareReset = 6
      end

      enum HardwareFault : UInt8
        # The Node has encountered an unspecified fault.
        Unspecified = 0

        # The Node has encountered a fault with at least one of its radios.
        Radio = 1

        # The Node has encountered a fault with at least one of its sensors.
        Sensor = 2

        # The Node has encountered an over-temperature fault that is resettable.
        ResettableOverTemp = 3

        # The Node has encountered an over-temperature fault that is not resettable.
        NonResettableOverTemp = 4

        # The Node has encountered a fault with at least one of its power sources.
        PowerSource = 5

        # The Node has encountered a fault with at least one of its visual displays.
        VisualDisplayFault = 6

        # The Node has encountered a fault with at least one of its audio outputs.
        AudioOutputFault = 7

        # The Node has encountered a fault with at least one of its user interfaces.
        UserInterfaceFault = 8

        # The Node has encountered a fault with its non-volatile memory.
        NonVolatileMemoryError = 9

        # The Node has encountered disallowed physical tampering.
        TamperDetected = 10
      end

      enum RadioFault : UInt8
        # The Node has encountered an unspecified radio fault.
        Unspecified = 0

        # The Node has encountered a fault with its Wi-Fi radio.
        WiFiFault = 1

        # The Node has encountered a fault with its cellular radio.
        CellularFault = 2

        # The Node has encountered a fault with its802.15.4 radio.
        ThreadFault = 3

        # The Node has encountered a fault with its NFC radio.
        NfcFault = 4

        # The Node has encountered a fault with its BLE radio.
        BleFault = 5

        # The Node has encountered a fault with its Ethernet controller.
        EthernetFault = 6
      end

      enum NetworkFault : UInt8
        # The Node has encountered an unspecified fault.
        Unspecified = 0

        # The Node has encountered a network fault as a result of a hardware failure.
        HardwareFailure = 1

        # The Node has encountered a network fault as a result of a jammed network.
        NetworkJammed = 2

        # The Node has encountered a network fault as a result of a failure to establish a connection.
        ConnectionFailed = 3
      end

      # This structure describes a network interface supported by the Node, as provided in the NetworkInterfaces
      # attribute.
      struct NetworkInterface
        include TLV::Serializable

        # This field shall indicate a human-readable (displayable) name for the network interface, that is different
        # from all other interfaces.
        @[TLV::Field(tag: 0)]
        property name : String

        # This field shall indicate if the Node is currently advertising itself operationally on this network
        # interface and is capable of successfully receiving incoming traffic from other Nodes.
        @[TLV::Field(tag: 1)]
        property? is_operational : Bool

        # This field shall indicate whether the Node is currently able to reach off-premise services it uses by
        # utilizing IPv4. The value shall be null if the Node does not use such services or does not know whether it
        # can reach them.
        @[TLV::Field(tag: 2)]
        property off_premise_services_reachable_ipv4 : Bool?

        # This field shall indicate whether the Node is currently able to reach off-premise services it uses by
        # utilizing IPv6. The value shall be null if the Node does not use such services or does not know whether it
        # can reach them.
        @[TLV::Field(tag: 3)]
        property off_premise_services_reachable_ipv6 : Bool?

        # This field shall contain the current link-layer address for a 802.3 or IEEE 802.11-2020 network interface
        # and contain the current extended MAC address for a 802.15.4 interface. The byte order of the octstr shall be
        # in wire byte order. For addresses values less than 64 bits, the first two bytes shall be zero.
        @[TLV::Field(tag: 4)]
        property hardware_address : Slice(UInt8)

        # This field shall provide a list of the IPv4 addresses that are currently assigned to the network interface.
        @[TLV::Field(tag: 5)]
        property ipv4_addresses : Array(Slice(UInt8))

        # This field shall provide a list of the unicast IPv6 addresses that are currently assigned to the network
        # interface. This list shall include the Node’s link-local address and SHOULD include any assigned GUA and ULA
        # addresses. This list shall NOT include any multicast group addresses to which the Node is subscribed.
        @[TLV::Field(tag: 6)]
        property ipv6_addresses : Array(Slice(UInt8))

        # This field shall indicate the type of the interface using the InterfaceTypeEnum.
        @[TLV::Field(tag: 7)]
        property type : InterfaceType
      end

      module Events
        struct HardwareFaultChange
          include TLV::Serializable

          # This field shall represent the set of faults currently detected, as per Section 11.11.4.1,
          # “HardwareFaultEnum”.
          @[TLV::Field(tag: 0)]
          property current : Array(HardwareFault)

          # This field shall represent the set of faults detected prior to this change event, as per Section
          #
          # 11.11.4.1, “HardwareFaultEnum”.
          @[TLV::Field(tag: 1)]
          property previous : Array(HardwareFault)
        end

        # Body of the GeneralDiagnostics radioFaultChange event
        struct RadioFaultChange
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property current : Array(RadioFault)

          @[TLV::Field(tag: 1)]
          property previous : Array(RadioFault)
        end

        # Body of the GeneralDiagnostics networkFaultChange event
        struct NetworkFaultChange
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property current : Array(NetworkFault)

          @[TLV::Field(tag: 1)]
          property previous : Array(NetworkFault)
        end

        # Body of the GeneralDiagnostics bootReason event
        struct BootReasonEvent
          include TLV::Serializable

          @[TLV::Field(tag: 0)]
          property boot_reason : BootReason

          def initialize(@boot_reason : BootReason)
          end
        end
      end

      # Network interface information
      struct NetworkInterfaceInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property name : String

        @[TLV::Field(tag: 1)]
        property? is_operational : Bool

        @[TLV::Field(tag: 2)]
        property off_premise_services_reachable_ipv4 : Bool?

        @[TLV::Field(tag: 3)]
        property off_premise_services_reachable_ipv6 : Bool?

        @[TLV::Field(tag: 4)]
        property hardware_address : Bytes

        @[TLV::Field(tag: 5)]
        property ipv4_addresses : Array(Bytes)

        @[TLV::Field(tag: 6)]
        property ipv6_addresses : Array(Bytes)

        @[TLV::Field(tag: 7)]
        property type : UInt8 # InterfaceType enum value

        def initialize(
          @name : String,
          @is_operational : Bool,
          @hardware_address : Bytes,
          interface_type : InterfaceType,
          @ipv4_addresses : Array(Bytes) = [] of Bytes,
          @ipv6_addresses : Array(Bytes) = [] of Bytes,
          @off_premise_services_reachable_ipv4 : Bool? = nil,
          @off_premise_services_reachable_ipv6 : Bool? = nil,
        )
          @type = interface_type.value
        end

        # Getter to convert back to InterfaceType enum
        def interface_type : InterfaceType
          InterfaceType.from_value(@type)
        end
      end

      # TestEventTrigger request: the 16 byte enable key and the trigger id.
      struct TestEventTriggerRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property enable_key : Bytes

        @[TLV::Field(tag: 1)]
        property event_trigger : UInt64

        def initialize(@enable_key : Bytes, @event_trigger : UInt64)
        end
      end

      # Matter 1.6 TimeSnapshotResponse (0x02). POSIX time is null until an
      # application supplies a synchronized time source.
      struct TimeSnapshotResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property system_time_ms : UInt64

        @[TLV::Field(tag: 1, optional: false)]
        property posix_time_ms : UInt64?

        def initialize(@system_time_ms : UInt64, @posix_time_ms : UInt64?)
        end
      end

      # UpTime and TotalOperationalHours are computed on read from the time
      # the cluster was created.
      attribute 0x0000, :network_interfaces, Array(NetworkInterfaceInfo), default: [] of NetworkInterfaceInfo
      attribute 0x0001, :reboot_count, UInt16, default: 0_u16
      attribute 0x0002, :up_time, UInt64, computed: true, omit_changes: true
      attribute 0x0003, :total_operational_hours, UInt32, computed: true, omit_changes: true, optional: true
      attribute 0x0004, :boot_reason, BootReason, default: BootReason::Unspecified, optional: true
      attribute 0x0005, :active_hardware_faults, Array(HardwareFault), default: [] of HardwareFault, optional: true
      attribute 0x0006, :active_radio_faults, Array(RadioFault), default: [] of RadioFault, optional: true
      attribute 0x0007, :active_network_faults, Array(NetworkFault), default: [] of NetworkFault, optional: true
      attribute 0x0008, :test_event_triggers_enabled, Bool, default: false

      command 0x00, :test_event_trigger, request: TestEventTriggerRequest, access: :manage
      command 0x01, :time_snapshot, response: TimeSnapshotResponse, response_id: 0x02, access: :operate

      event 0x03, :boot_reason, priority: :critical, payload: Events::BootReasonEvent

      @start_time : Time
      @start_instant : Time::Instant

      # Return synchronized POSIX milliseconds, or nil when unavailable.
      property on_posix_time_ms : Proc(UInt64?)?

      def initialize(
        endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber.new(0_u16),
        @reboot_count : UInt16 = 0_u16,
        @boot_reason : BootReason = BootReason::Unspecified,
      )
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        @start_time = Time.utc
        @start_instant = Time.instant
        @on_posix_time_ms = nil
      end

      def time_snapshot : TimeSnapshotResponse
        elapsed_ms = (Time.instant - @start_instant).total_milliseconds.to_u64
        TimeSnapshotResponse.new(elapsed_ms, @on_posix_time_ms.try(&.call))
      end

      def emit_boot_reason_event : Nil
        emit_event(EVENT_BOOT_REASON, Events::BootReasonEvent.new(@boot_reason))
      end

      # UpTime attribute (0x02): seconds since the cluster was created
      def up_time : UInt64
        elapsed.total_seconds.to_u64
      end

      # TotalOperationalHours attribute (0x03)
      def total_operational_hours : UInt32
        elapsed.total_hours.to_u32
      end

      private def elapsed : Time::Span
        Time.utc - @start_time
      end

      # Test event triggers are never enabled on a production device, so no
      # enable key matches.
      def test_event_trigger(request : TestEventTriggerRequest) : InteractionModel::Status
        InteractionModel::Status.constraint_error
      end

      # Add a network interface
      def add_network_interface(interface : NetworkInterfaceInfo) : Nil
        @network_interfaces << interface
        increment_version_and_notify(ATTR_NETWORK_INTERFACES)
      end
    end
  end
end
