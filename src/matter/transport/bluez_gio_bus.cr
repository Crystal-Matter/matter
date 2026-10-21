require "./bluez_central"

{% if flag?(:linux) %}
  @[Link("gio-2.0")]
  @[Link("gobject-2.0")]
  @[Link("glib-2.0")]
  lib LibMatterBluezGio
    struct Error
      domain : UInt32
      code : Int32
      message : UInt8*
    end

    fun g_bus_get_sync(bus_type : Int32, cancellable : Void*, error : Error**) : Void*
    fun g_dbus_connection_call_sync(connection : Void*, bus_name : UInt8*, object_path : UInt8*,
                                    interface_name : UInt8*, method_name : UInt8*, parameters : Void*,
                                    reply_type : Void*, flags : Int32, timeout_msec : Int32,
                                    cancellable : Void*, error : Error**) : Void*
    fun g_dbus_connection_call_with_unix_fd_list_sync(connection : Void*, bus_name : UInt8*, object_path : UInt8*,
                                                      interface_name : UInt8*, method_name : UInt8*, parameters : Void*,
                                                      reply_type : Void*, flags : Int32, timeout_msec : Int32,
                                                      fd_list : Void*, out_fd_list : Void**, cancellable : Void*,
                                                      error : Error**) : Void*
    fun g_unix_fd_list_get(fd_list : Void*, index : Int32, error : Error**) : Int32
    fun g_variant_parse(type : Void*, text : UInt8*, limit : Void*, endptr : Void*, error : Error**) : Void*
    fun g_variant_n_children(value : Void*) : LibC::SizeT
    fun g_variant_get_child_value(value : Void*, index : LibC::SizeT) : Void*
    fun g_variant_get_string(value : Void*, length : LibC::SizeT*) : UInt8*
    fun g_variant_get_handle(value : Void*) : Int32
    fun g_variant_get_uint16(value : Void*) : UInt16
    fun g_variant_lookup_value(value : Void*, key : UInt8*, expected_type : Void*) : Void*
    fun g_variant_get_fixed_array(value : Void*, n_elements : LibC::SizeT*, element_size : LibC::SizeT) : UInt8*
    fun g_variant_ref_sink(value : Void*) : Void*
    fun g_variant_unref(value : Void*) : Void
    fun g_error_free(error : Error*) : Void
    fun g_object_unref(object : Void*) : Void
  end

  module Matter
    module Transport
      module Bluez
        # Linux system-bus implementation. The object inventory is polled while
        # scanning and after connecting, so no GLib main loop or signal thread is
        # required. AcquireNotify supplies packet-preserving C2 indications.
        class GioBus < Bus
          BLUEZ_NAME               = "org.bluez"
          OBJECT_MANAGER           = "org.freedesktop.DBus.ObjectManager"
          ADAPTER_INTERFACE        = "org.bluez.Adapter1"
          DEVICE_INTERFACE         = "org.bluez.Device1"
          SERVICE_INTERFACE        = "org.bluez.GattService1"
          CHARACTERISTIC_INTERFACE = "org.bluez.GattCharacteristic1"
          DBUS_TIMEOUT_MS          = 15_000
          SYSTEM_BUS               =      2
          DBUS_FLAGS_NONE          =      0
          BYTE_SIZE                =      1
          MAX_NOTIFICATION_SIZE    =    512

          @connection : Void*

          def initialize(@adapter_path : String = "/org/bluez/hci0")
            error = Pointer(LibMatterBluezGio::Error).null
            @connection = LibMatterBluezGio.g_bus_get_sync(SYSTEM_BUS, Pointer(Void).null, pointerof(error))
            check_error(error, "connect to system D-Bus")
            raise Matter::TransportError.new("Cannot connect to system D-Bus") if @connection.null?
          end

          def finalize
            LibMatterBluezGio.g_object_unref(@connection) unless @connection.null?
          end

          def start_scan(service_uuid : String) : Nil
            filter = parse_variant("({'UUIDs': <['#{service_uuid}']>, 'Transport': <'le'>},)")
            begin
              call(@adapter_path, ADAPTER_INTERFACE, "SetDiscoveryFilter", filter)
            ensure
              LibMatterBluezGio.g_variant_unref(filter)
            end
            call(@adapter_path, ADAPTER_INTERFACE, "StartDiscovery")
          end

          def stop_scan : Nil
            call(@adapter_path, ADAPTER_INTERFACE, "StopDiscovery")
          end

          def devices : Array(Device)
            objects = Pointer(Void).null
            objects = managed_objects
            result = [] of Device
            each_object(objects) do |path, interfaces|
              if properties = lookup(interfaces, DEVICE_INTERFACE)
                begin
                  if address = string_property(properties, "Address")
                    if data = lookup(properties, "ServiceData")
                      begin
                        if bytes = lookup(data, SERVICE_UUID)
                          begin
                            result << Device.new(path, address, bytes_value(bytes))
                          ensure
                            LibMatterBluezGio.g_variant_unref(bytes)
                          end
                        end
                      ensure
                        LibMatterBluezGio.g_variant_unref(data)
                      end
                    end
                  end
                ensure
                  LibMatterBluezGio.g_variant_unref(properties)
                end
              end
            end
            result
          ensure
            LibMatterBluezGio.g_variant_unref(objects) if objects
          end

          def connect_device(path : String) : Nil
            call(path, DEVICE_INTERFACE, "Connect")
          end

          def services(device_path : String) : Array(Service)
            objects = Pointer(Void).null
            objects = managed_objects
            result = [] of Service
            each_object(objects) do |path, interfaces|
              next unless path.starts_with?("#{device_path}/")
              if properties = lookup(interfaces, SERVICE_INTERFACE)
                begin
                  if uuid = string_property(properties, "UUID")
                    result << Service.new(path, uuid)
                  end
                ensure
                  LibMatterBluezGio.g_variant_unref(properties)
                end
              end
            end
            result
          ensure
            LibMatterBluezGio.g_variant_unref(objects) if objects
          end

          def characteristics(service_path : String) : Array(Characteristic)
            objects = Pointer(Void).null
            objects = managed_objects
            result = [] of Characteristic
            each_object(objects) do |path, interfaces|
              next unless path.starts_with?("#{service_path}/")
              if properties = lookup(interfaces, CHARACTERISTIC_INTERFACE)
                begin
                  if uuid = string_property(properties, "UUID")
                    result << Characteristic.new(path, uuid)
                  end
                ensure
                  LibMatterBluezGio.g_variant_unref(properties)
                end
              end
            end
            result
          ensure
            LibMatterBluezGio.g_variant_unref(objects) if objects
          end

          def write(characteristic_path : String, frame : Bytes) : Nil
            octets = frame.map { |byte| "byte 0x#{byte.to_s(16).rjust(2, '0')}" }.join(", ")
            parameters = parse_variant("([#{octets}], {'type': <'request'>})")
            begin
              call(characteristic_path, CHARACTERISTIC_INTERFACE, "WriteValue", parameters)
            ensure
              LibMatterBluezGio.g_variant_unref(parameters)
            end
          end

          def subscribe(characteristic_path : String) : Notifications
            parameters = parse_variant("(@a{sv} {},)")
            error = Pointer(LibMatterBluezGio::Error).null
            fd_list = Pointer(Void).null
            handle_value = Pointer(Void).null
            mtu_value = Pointer(Void).null
            reply = Pointer(Void).null
            begin
              reply = LibMatterBluezGio.g_dbus_connection_call_with_unix_fd_list_sync(
                @connection, BLUEZ_NAME, characteristic_path, CHARACTERISTIC_INTERFACE,
                "AcquireNotify", parameters, Pointer(Void).null, DBUS_FLAGS_NONE, DBUS_TIMEOUT_MS,
                Pointer(Void).null, pointerof(fd_list), Pointer(Void).null, pointerof(error))
              check_error(error, "acquire C2 indications")
              raise Matter::TransportError.new("BlueZ AcquireNotify returned no reply") if reply.null?
              raise Matter::TransportError.new("BlueZ AcquireNotify returned no file descriptors") if fd_list.null?
              handle_value = LibMatterBluezGio.g_variant_get_child_value(reply, 0)
              mtu_value = LibMatterBluezGio.g_variant_get_child_value(reply, 1)
              handle = LibMatterBluezGio.g_variant_get_handle(handle_value)
              mtu = LibMatterBluezGio.g_variant_get_uint16(mtu_value).to_i
              error = Pointer(LibMatterBluezGio::Error).null
              fd = LibMatterBluezGio.g_unix_fd_list_get(fd_list, handle, pointerof(error))
              check_error(error, "read C2 indication descriptor")
              raise Matter::TransportError.new("BlueZ returned an invalid C2 descriptor") if fd < 0
              FdNotifications.new(fd, mtu)
            ensure
              LibMatterBluezGio.g_variant_unref(parameters)
              LibMatterBluezGio.g_variant_unref(handle_value) unless handle_value.null?
              LibMatterBluezGio.g_variant_unref(mtu_value) unless mtu_value.null?
              LibMatterBluezGio.g_variant_unref(reply) unless reply.null?
              LibMatterBluezGio.g_object_unref(fd_list) unless fd_list.null?
            end
          end

          def disconnect_device(path : String) : Nil
            call(path, DEVICE_INTERFACE, "Disconnect")
          end

          private def call(path : String, interface : String, method : String, parameters : Void* = Pointer(Void).null) : Nil
            error = Pointer(LibMatterBluezGio::Error).null
            reply = LibMatterBluezGio.g_dbus_connection_call_sync(@connection, BLUEZ_NAME,
              path, interface, method, parameters, Pointer(Void).null, DBUS_FLAGS_NONE,
              DBUS_TIMEOUT_MS, Pointer(Void).null, pointerof(error))
            check_error(error, "#{interface}.#{method}")
            raise Matter::TransportError.new("BlueZ #{method} returned no reply") if reply.null?
            LibMatterBluezGio.g_variant_unref(reply)
          end

          private def managed_objects : Void*
            error = Pointer(LibMatterBluezGio::Error).null
            reply = LibMatterBluezGio.g_dbus_connection_call_sync(@connection, BLUEZ_NAME,
              "/", OBJECT_MANAGER, "GetManagedObjects", Pointer(Void).null,
              Pointer(Void).null, DBUS_FLAGS_NONE, DBUS_TIMEOUT_MS, Pointer(Void).null,
              pointerof(error))
            check_error(error, "enumerate BlueZ objects")
            raise Matter::TransportError.new("BlueZ returned no managed objects") if reply.null?
            objects = LibMatterBluezGio.g_variant_get_child_value(reply, 0)
            LibMatterBluezGio.g_variant_unref(reply)
            objects
          end

          private def each_object(objects : Void*, &block : String, Void* ->) : Nil
            LibMatterBluezGio.g_variant_n_children(objects).times do |index|
              entry = LibMatterBluezGio.g_variant_get_child_value(objects, index.to_u64)
              path_value = LibMatterBluezGio.g_variant_get_child_value(entry, 0)
              interfaces = LibMatterBluezGio.g_variant_get_child_value(entry, 1)
              begin
                yield String.new(LibMatterBluezGio.g_variant_get_string(path_value, Pointer(LibC::SizeT).null)), interfaces
              ensure
                LibMatterBluezGio.g_variant_unref(interfaces)
                LibMatterBluezGio.g_variant_unref(path_value)
                LibMatterBluezGio.g_variant_unref(entry)
              end
            end
          end

          private def lookup(dictionary : Void*, key : String) : Void*?
            value = LibMatterBluezGio.g_variant_lookup_value(dictionary, key, Pointer(Void).null)
            value.null? ? nil : value
          end

          private def string_property(properties : Void*, key : String) : String?
            value = nil
            return unless value = lookup(properties, key)
            String.new(LibMatterBluezGio.g_variant_get_string(value, Pointer(LibC::SizeT).null))
          ensure
            LibMatterBluezGio.g_variant_unref(value) if value
          end

          private def bytes_value(value : Void*) : Bytes
            count = uninitialized LibC::SizeT
            pointer = LibMatterBluezGio.g_variant_get_fixed_array(value, pointerof(count), BYTE_SIZE)
            return Bytes.new(0) if pointer.null? || count == 0
            Bytes.new(pointer, count.to_i).dup
          end

          private def parse_variant(source : String) : Void*
            error = Pointer(LibMatterBluezGio::Error).null
            value = LibMatterBluezGio.g_variant_parse(Pointer(Void).null, source,
              Pointer(Void).null, Pointer(Void).null, pointerof(error))
            check_error(error, "encode BlueZ D-Bus arguments")
            raise Matter::TransportError.new("Cannot encode BlueZ D-Bus arguments") if value.null?
            # GDBus consumes floating parameter variants. Hold an ordinary
            # reference so the caller can release it after the synchronous call.
            LibMatterBluezGio.g_variant_ref_sink(value)
          end

          private def check_error(error : LibMatterBluezGio::Error*, action : String) : Nil
            return if error.null?
            message = String.new(error.value.message)
            LibMatterBluezGio.g_error_free(error)
            raise Matter::TransportError.new("Cannot #{action}: #{message}")
          end
        end

        class FdNotifications < Notifications
          getter mtu : Int32?

          def initialize(fd : Int32, @mtu : Int32?)
            @io = IO::FileDescriptor.new(fd)
          end

          def read(timeout_span : Time::Span) : Bytes?
            @io.read_timeout = timeout_span
            buffer = Bytes.new(GioBus::MAX_NOTIFICATION_SIZE)
            count = @io.read(buffer)
            count == 0 ? nil : buffer[0, count].dup
          rescue IO::TimeoutError
            nil
          end

          def close : Nil
            @io.close
          end
        end
      end
    end
  end
{% end %}
