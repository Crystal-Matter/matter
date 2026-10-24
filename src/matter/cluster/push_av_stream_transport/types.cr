require "tlv"
require "../../storage/record"

module Matter
  module Cluster
    class PushAvStreamTransport < Base
      enum StatusCode : UInt8
        InvalidTlsEndpoint     = 0x02
        InvalidStream          = 0x03
        InvalidUrl             = 0x04
        InvalidZone            = 0x05
        InvalidCombination     = 0x06
        InvalidTriggerType     = 0x07
        InvalidTransportStatus = 0x08
        InvalidOptions         = 0x09
        InvalidStreamUsage     = 0x0A
        InvalidTime            = 0x0B
        InvalidPreRollLength   = 0x0C
        DuplicateStreamValues  = 0x0D
      end

      enum CmafInterface : UInt8
        Interface1
        Interface2Dash
        Interface2Hls
      end

      enum ContainerFormat : UInt8
        Cmaf
      end

      enum IngestMethod : UInt8
        CmafIngest
      end

      enum TransportStatus : UInt8
        Active
        Inactive
      end

      enum TriggerType : UInt8
        Command
        Motion
        Continuous
      end

      enum ActivationReason : UInt8
        UserInitiated
        Automation
        Emergency
        DoorbellPressed
      end

      enum StreamUsage : UInt8
        Internal
        Recording
        Analysis
        LiveView
      end

      module Tlv
        struct VideoStream
          include ::TLV::Serializable
          include Storage::Record

          @[::TLV::Field(tag: 0)]
          getter name : String
          @[::TLV::Field(tag: 1)]
          getter id : UInt16

          def initialize(@name : String, @id : UInt16); end
        end

        struct AudioStream
          include ::TLV::Serializable
          include Storage::Record

          @[::TLV::Field(tag: 0)]
          getter name : String
          @[::TLV::Field(tag: 1)]
          getter id : UInt16

          def initialize(@name : String, @id : UInt16); end
        end

        struct CmafContainerOptions
          include ::TLV::Serializable
          include Storage::Record

          @[::TLV::Field(tag: 0)]
          getter cmaf_interface : CmafInterface
          @[::TLV::Field(tag: 1)]
          getter segment_duration : UInt16
          @[::TLV::Field(tag: 2)]
          getter chunk_duration : UInt16
          @[::TLV::Field(tag: 3, optional: true)]
          getter session_group : UInt8?
          @[::TLV::Field(tag: 4, optional: true)]
          getter track_name : String?
          @[::TLV::Field(tag: 7, optional: true)]
          getter metadata_enabled : Bool?

          def initialize(@cmaf_interface : CmafInterface, @segment_duration : UInt16, @chunk_duration : UInt16,
                         @session_group : UInt8? = nil, @track_name : String? = nil, @metadata_enabled : Bool? = nil); end
        end

        struct ContainerOptions
          include ::TLV::Serializable
          include Storage::Record

          @[::TLV::Field(tag: 0)]
          getter container_type : ContainerFormat
          @[::TLV::Field(tag: 1)]
          getter cmaf : CmafContainerOptions

          def initialize(@container_type : ContainerFormat, @cmaf : CmafContainerOptions); end
        end

        struct SupportedFormat
          include ::TLV::Serializable

          @[::TLV::Field(tag: 0)]
          getter container_format : ContainerFormat
          @[::TLV::Field(tag: 1)]
          getter ingest_method : IngestMethod

          def initialize(@container_format : ContainerFormat, @ingest_method : IngestMethod); end
        end

        struct MotionTimeControl
          include ::TLV::Serializable
          include Storage::Record

          @[::TLV::Field(tag: 0)]
          getter initial_duration : UInt16
          @[::TLV::Field(tag: 1)]
          getter augmentation_duration : UInt16
          @[::TLV::Field(tag: 2)]
          getter max_duration : UInt32
          @[::TLV::Field(tag: 3)]
          getter blind_duration : UInt16

          def initialize(@initial_duration : UInt16, @augmentation_duration : UInt16,
                         @max_duration : UInt32, @blind_duration : UInt16); end
        end

        struct ZoneOptions
          include ::TLV::Serializable
          include Storage::Record

          @[::TLV::Field(tag: 0, optional: false)]
          getter zone : UInt16?
          @[::TLV::Field(tag: 1, optional: true)]
          getter sensitivity : UInt8?

          def initialize(@zone : UInt16?, @sensitivity : UInt8? = nil); end
        end

        struct TriggerOptions
          include ::TLV::Serializable
          include Storage::Record

          @[::TLV::Field(tag: 0)]
          getter trigger_type : TriggerType
          @[::TLV::Field(tag: 1, optional: true)]
          getter motion_zones : Array(ZoneOptions)?
          @[::TLV::Field(tag: 2, optional: true)]
          getter motion_sensitivity : UInt8?
          @[::TLV::Field(tag: 3, optional: true)]
          getter motion_time_control : MotionTimeControl?
          @[::TLV::Field(tag: 4, optional: true)]
          getter max_pre_roll_len : UInt16?

          def initialize(@trigger_type : TriggerType, @motion_zones : Array(ZoneOptions)? = nil,
                         @motion_sensitivity : UInt8? = nil, @motion_time_control : MotionTimeControl? = nil,
                         @max_pre_roll_len : UInt16? = nil); end
        end

        struct TransportOptions
          include ::TLV::Serializable
          include Storage::Record

          @[::TLV::Field(tag: 0)]
          getter stream_usage : StreamUsage
          @[::TLV::Field(tag: 1, optional: true)]
          getter video_stream_id : UInt16?
          @[::TLV::Field(tag: 2, optional: true)]
          getter audio_stream_id : UInt16?
          @[::TLV::Field(tag: 3)]
          getter tls_endpoint_id : UInt16
          @[::TLV::Field(tag: 4)]
          getter url : String
          @[::TLV::Field(tag: 5)]
          getter trigger_options : TriggerOptions
          @[::TLV::Field(tag: 6)]
          getter ingest_method : IngestMethod
          @[::TLV::Field(tag: 7)]
          getter container_options : ContainerOptions
          @[::TLV::Field(tag: 8, optional: true)]
          getter expiry_time : UInt32?
          @[::TLV::Field(tag: 9, optional: true)]
          getter video_streams : Array(VideoStream)?
          @[::TLV::Field(tag: 10, optional: true)]
          getter audio_streams : Array(AudioStream)?

          def initialize(@stream_usage : StreamUsage, @tls_endpoint_id : UInt16, @url : String,
                         @trigger_options : TriggerOptions, @ingest_method : IngestMethod,
                         @container_options : ContainerOptions, @video_stream_id : UInt16? = nil,
                         @audio_stream_id : UInt16? = nil, @expiry_time : UInt32? = nil,
                         @video_streams : Array(VideoStream)? = nil, @audio_streams : Array(AudioStream)? = nil); end
        end

        struct TransportConfiguration
          include ::TLV::Serializable
          include Storage::Record

          @[::TLV::Field(tag: 0)]
          getter connection_id : UInt16
          @[::TLV::Field(tag: 1)]
          getter transport_status : TransportStatus
          @[::TLV::Field(tag: 2, optional: true)]
          getter transport_options : TransportOptions?
          @[::TLV::Field(tag: 254)]
          getter fabric_index : UInt8

          def initialize(@connection_id : UInt16, @transport_status : TransportStatus,
                         @transport_options : TransportOptions?, @fabric_index : UInt8); end
        end

        struct AllocateRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter transport_options : TransportOptions

          def initialize(@transport_options : TransportOptions); end
        end

        struct AllocateResponse
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter transport_configuration : TransportConfiguration

          def initialize(@transport_configuration : TransportConfiguration); end
        end

        struct DeallocateRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter connection_id : UInt16

          def initialize(@connection_id : UInt16); end
        end

        struct ModifyRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter connection_id : UInt16
          @[::TLV::Field(tag: 1)]
          getter transport_options : TransportOptions

          def initialize(@connection_id : UInt16, @transport_options : TransportOptions); end
        end

        struct SetStatusRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0, optional: false)]
          getter connection_id : UInt16?
          @[::TLV::Field(tag: 1)]
          getter transport_status : TransportStatus

          def initialize(@connection_id : UInt16?, @transport_status : TransportStatus); end
        end

        struct ManualTriggerRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter connection_id : UInt16
          @[::TLV::Field(tag: 1)]
          getter activation_reason : ActivationReason
          @[::TLV::Field(tag: 2, optional: true)]
          getter time_control : MotionTimeControl?
          @[::TLV::Field(tag: 3, optional: true)]
          getter user_defined : Bytes?

          def initialize(@connection_id : UInt16, @activation_reason : ActivationReason,
                         @time_control : MotionTimeControl? = nil, @user_defined : Bytes? = nil); end
        end

        struct FindRequest
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0, optional: false)]
          getter connection_id : UInt16?

          def initialize(@connection_id : UInt16?); end
        end

        struct FindResponse
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter transport_configurations : Array(TransportConfiguration)

          def initialize(@transport_configurations : Array(TransportConfiguration)); end
        end

        struct BeginEvent
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter connection_id : UInt16
          @[::TLV::Field(tag: 1)]
          getter trigger_type : TriggerType
          @[::TLV::Field(tag: 2, optional: true)]
          getter activation_reason : ActivationReason?
          @[::TLV::Field(tag: 3)]
          getter container_type : ContainerFormat
          @[::TLV::Field(tag: 4)]
          getter cmaf_session_number : UInt64

          def initialize(@connection_id : UInt16, @trigger_type : TriggerType,
                         @activation_reason : ActivationReason?, @container_type : ContainerFormat,
                         @cmaf_session_number : UInt64); end
        end

        struct EndEvent
          include ::TLV::Serializable
          @[::TLV::Field(tag: 0)]
          getter connection_id : UInt16
          @[::TLV::Field(tag: 1)]
          getter container_type : ContainerFormat
          @[::TLV::Field(tag: 2)]
          getter cmaf_session_number : UInt64

          def initialize(@connection_id : UInt16, @container_type : ContainerFormat,
                         @cmaf_session_number : UInt64); end
        end
      end
    end
  end
end
