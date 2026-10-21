require "./cluster"
require "tlv"

module Matter
  module Cluster
    # Optional process and heap diagnostics supplied by the device application.
    class SoftwareDiagnostics < Base
      cluster 0x0034, revision: 1

      MAX_THREAD_METRICS =   64
      MAX_NAME_LENGTH    =    8
      MAX_FAULT_RECORD   = 1024

      feature :watermarks, bit: 0

      struct ThreadMetricsStruct
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property id : UInt64

        @[TLV::Field(tag: 1)]
        property name : String?

        @[TLV::Field(tag: 2)]
        property stack_free_current : UInt32?

        @[TLV::Field(tag: 3)]
        property stack_free_minimum : UInt32?

        @[TLV::Field(tag: 4)]
        property stack_size : UInt32?

        def initialize(@id : UInt64, @name : String? = nil,
                       @stack_free_current : UInt32? = nil,
                       @stack_free_minimum : UInt32? = nil,
                       @stack_size : UInt32? = nil)
          raise ArgumentError.new("thread name exceeds #{MAX_NAME_LENGTH} bytes") if @name.try(&.bytesize).try { |size| size > MAX_NAME_LENGTH }
        end
      end

      struct SoftwareFaultEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property id : UInt64

        @[TLV::Field(tag: 1)]
        property name : String?

        @[TLV::Field(tag: 2)]
        property fault_recording : Bytes?

        def initialize(@id : UInt64, @name : String? = nil,
                       @fault_recording : Bytes? = nil)
          raise ArgumentError.new("software fault name exceeds #{MAX_NAME_LENGTH} bytes") if @name.try(&.bytesize).try { |size| size > MAX_NAME_LENGTH }
          raise ArgumentError.new("software fault recording exceeds #{MAX_FAULT_RECORD} bytes") if @fault_recording.try(&.size).try { |size| size > MAX_FAULT_RECORD }
        end
      end

      attribute 0x0000, :thread_metrics, Array(ThreadMetricsStruct),
        default: [] of ThreadMetricsStruct, optional: true
      attribute 0x0001, :current_heap_free, UInt64,
        nullable: true, optional: true, present_if: :current_heap_free
      attribute 0x0002, :current_heap_used, UInt64,
        nullable: true, optional: true, present_if: :current_heap_used
      attribute 0x0003, :current_heap_high_watermark, UInt64,
        default: 0_u64, requires: :watermarks

      event 0x0000, :software_fault, priority: :info
      command 0x0000, :reset_watermarks, requires: :watermarks, access: :manage

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     @thread_metrics : Array(ThreadMetricsStruct) = [] of ThreadMetricsStruct,
                     @current_heap_free : UInt64? = nil,
                     @current_heap_used : UInt64? = nil,
                     @current_heap_high_watermark : UInt64 = 0_u64)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_thread_metrics!(@thread_metrics)
        @thread_metrics = @thread_metrics.dup
        if used = @current_heap_used
          @current_heap_high_watermark = Math.max(@current_heap_high_watermark, used)
        end
      end

      def update_thread_metrics(metrics : Array(ThreadMetricsStruct)) : Nil
        validate_thread_metrics!(metrics)
        self.thread_metrics = metrics.dup
      end

      def update_heap(free : UInt64, used : UInt64) : Nil
        self.current_heap_free = free
        self.current_heap_used = used
        self.current_heap_high_watermark = Math.max(@current_heap_high_watermark, used) if @feature_map.watermarks?
      end

      def reset_watermarks : InteractionModel::Status
        self.current_heap_high_watermark = @current_heap_used || 0_u64
        InteractionModel::Status.success
      end

      def emit_software_fault(id : UInt64, name : String? = nil,
                              fault_recording : Bytes? = nil) : Bytes
        payload = SoftwareFaultEvent.new(id, name, fault_recording)
        emit_event(EVENT_SOFTWARE_FAULT, payload)
        payload.to_slice
      end

      private def validate_thread_metrics!(metrics : Array(ThreadMetricsStruct)) : Nil
        raise ArgumentError.new("thread metrics exceed #{MAX_THREAD_METRICS} entries") if metrics.size > MAX_THREAD_METRICS
      end
    end
  end
end
