require "./cluster"
require "./camera_av_stream_management"
require "../storage/record"

module Matter
  module Cluster
    # Matter 1.6 Camera AV Settings User Level Management server.
    # The host starts the actuator in a callback and reports its measured
    # position. Optional presets capture and persist those measured settings.
    class CameraAvSettingsUserLevelManagement < Base
      cluster 0x0552, revision: 1

      feature :digital_ptz, bit: 0
      feature :mechanical_pan, bit: 1
      feature :mechanical_presets, bit: 4

      PAN_MIN_LIMIT         = -180_i16
      PAN_MAX_LIMIT         =  180_i16
      ZERO_PAN              =    0_i16
      MAX_PRESET_NAME_BYTES =       32

      enum PhysicalMovement : UInt8
        Idle   = 0
        Moving = 1
      end

      struct MPTZPosition
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter pan : Int16

        def initialize(@pan : Int16)
        end
      end

      struct MPTZSetPositionRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter pan : Int16?

        def initialize(@pan : Int16? = nil)
        end
      end

      struct MPTZRelativeMoveRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter pan_delta : Int16?

        def initialize(@pan_delta : Int16? = nil)
        end
      end

      struct MPTZPreset
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter preset_id : UInt8

        @[TLV::Field(tag: 1)]
        getter name : String

        @[TLV::Field(tag: 2)]
        getter settings : MPTZPosition

        def initialize(@preset_id : UInt8, @name : String, @settings : MPTZPosition)
        end
      end

      struct MPTZMoveToPresetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter preset_id : UInt8

        def initialize(@preset_id : UInt8)
        end
      end

      struct MPTZSavePresetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter preset_id : UInt8?

        @[TLV::Field(tag: 1)]
        getter name : String

        def initialize(@preset_id : UInt8?, @name : String)
        end
      end

      struct MPTZRemovePresetRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter preset_id : UInt8

        def initialize(@preset_id : UInt8)
        end
      end

      struct DPTZStream
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter video_stream_id : UInt16

        @[TLV::Field(tag: 1)]
        getter viewport : CameraAvStreamManagement::Viewport

        def initialize(@video_stream_id : UInt16, @viewport : CameraAvStreamManagement::Viewport)
        end
      end

      struct DPTZSetViewportRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter video_stream_id : UInt16

        @[TLV::Field(tag: 1)]
        getter viewport : CameraAvStreamManagement::Viewport

        def initialize(@video_stream_id : UInt16, @viewport : CameraAvStreamManagement::Viewport)
        end
      end

      attribute 0x0000, :mptz_position, MPTZPosition,
        default: MPTZPosition.new(ZERO_PAN), persist: true,
        requires: :mechanical_pan, validate: :validate_position!
      attribute 0x0001, :max_presets, UInt8, default: 0_u8,
        fixed: true, requires: :mechanical_presets, validate: :validate_max_presets!
      attribute 0x0002, :mptz_presets, Array(MPTZPreset), default: [] of MPTZPreset,
        persist: true, persist_default: [] of MPTZPreset, requires: :mechanical_presets,
        copy_on_assign: true, copy_on_read: true, validate: :validate_presets!
      attribute 0x0003, :dptz_streams, Array(DPTZStream), default: [] of DPTZStream,
        persist: true, persist_default: [] of DPTZStream, requires: :digital_ptz,
        copy_on_assign: true, copy_on_read: true, validate: :validate_dptz_streams!
      attribute 0x0007, :pan_min, Int16, default: PAN_MIN_LIMIT,
        requires: :mechanical_pan, validate: :validate_pan_min!
      attribute 0x0008, :pan_max, Int16, default: PAN_MAX_LIMIT,
        requires: :mechanical_pan, validate: :validate_pan_max!
      attribute 0x0009, :movement_state, PhysicalMovement,
        default: PhysicalMovement::Idle, requires: :mechanical_pan

      command 0x00, :mptz_set_position, request: MPTZSetPositionRequest,
        access: :operate, requires: :mechanical_pan
      command 0x01, :mptz_relative_move, request: MPTZRelativeMoveRequest,
        access: :operate, requires: :mechanical_pan
      command 0x02, :mptz_move_to_preset, request: MPTZMoveToPresetRequest,
        access: :operate, requires: :mechanical_presets
      command 0x03, :mptz_save_preset, request: MPTZSavePresetRequest,
        access: :operate, requires: :mechanical_presets
      command 0x04, :mptz_remove_preset, request: MPTZRemovePresetRequest,
        access: :operate, requires: :mechanical_presets
      command 0x05, :dptz_set_viewport, request: DPTZSetViewportRequest,
        access: :operate, requires: :digital_ptz

      @on_pan_move : Proc(Int16, InteractionModel::Status)?
      @on_preset_save : Proc(MPTZPreset, InteractionModel::Status)?
      @on_preset_remove : Proc(UInt8, InteractionModel::Status)?
      @on_dptz_set_viewport : Proc(UInt16, CameraAvStreamManagement::Viewport, InteractionModel::Status)?
      @video_stream_management : CameraAvStreamManagement?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @pan_min : Int16 = PAN_MIN_LIMIT,
                     @pan_max : Int16 = PAN_MAX_LIMIT,
                     initial_pan : Int16 = ZERO_PAN,
                     @max_presets : UInt8 = 0_u8,
                     video_stream_management : CameraAvStreamManagement? = nil,
                     @feature_map : Feature = Feature::MechanicalPan)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        unless @feature_map.in?(Feature::DigitalPtz, Feature::MechanicalPan,
                 Feature::MechanicalPan | Feature::MechanicalPresets)
          raise ArgumentError.new("only DigitalPTZ, MechanicalPan and MPAN+MPRESETS profiles are implemented")
        end
        if @feature_map.digital_ptz?
          source = video_stream_management || raise ArgumentError.new("DigitalPTZ requires Video stream management")
          unless source.endpoint_id == endpoint_id && source.feature_map.video?
            raise ArgumentError.new("DigitalPTZ requires same-endpoint Video stream management")
          end
          @video_stream_management = source
          source.on_video_released { |id| remove_dptz_stream(id) }
          source.on_viewport_changed { |viewport| update_dptz_viewports(viewport) }
        else
          @video_stream_management = nil
        end
        raise ArgumentError.new("MaxPresets must be positive for MechanicalPresets") if @feature_map.mechanical_presets? && @max_presets.zero?
        unless (PAN_MIN_LIMIT..ZERO_PAN).includes?(@pan_min) &&
               (1_i16..PAN_MAX_LIMIT).includes?(@pan_max)
          raise ArgumentError.new("pan limits must be -180..0 and 1..180")
        end
        validate_pan!(initial_pan)
        @mptz_position = MPTZPosition.new(initial_pan)
      end

      # The callback starts physical movement to target and returns the
      # command status. Report completion with #report_pan_position.
      def on_pan_move(&block : Int16 -> InteractionModel::Status) : Nil
        @on_pan_move = block
      end

      # Called before a measured position is saved as a preset.
      def on_preset_save(&block : MPTZPreset -> InteractionModel::Status) : Nil
        @on_preset_save = block
      end

      # Called before a preset is removed.
      def on_preset_remove(&block : UInt8 -> InteractionModel::Status) : Nil
        @on_preset_remove = block
      end

      # The host calls this after allocating a VDO stream that supports digital
      # movement. Its initial viewport is the global Camera AV viewport.
      def register_dptz_stream(video_stream_id : UInt16) : InteractionModel::Status
        source = @video_stream_management || return InteractionModel::Status.invalid_in_state
        return InteractionModel::Status.not_found unless source.allocated_video_streams.any?(&.video_stream_id.==(video_stream_id))
        return InteractionModel::Status.success if @dptz_streams.any?(&.video_stream_id.==(video_stream_id))
        self.dptz_streams = @dptz_streams + [DPTZStream.new(video_stream_id, source.viewport)]
        InteractionModel::Status.success
      end

      # The host applies the crop to actual video before state is committed.
      def on_dptz_set_viewport(&block : UInt16, CameraAvStreamManagement::Viewport -> InteractionModel::Status) : Nil
        @on_dptz_set_viewport = block
      end

      def mptz_set_position(request : MPTZSetPositionRequest) : InteractionModel::Status
        pan = request.pan
        return InteractionModel::Status.constraint_error unless pan
        move_pan(pan)
      end

      def mptz_relative_move(request : MPTZRelativeMoveRequest) : InteractionModel::Status
        delta = request.pan_delta
        return InteractionModel::Status.constraint_error unless delta
        maximum_delta = @pan_max.to_i32 - @pan_min.to_i32
        return InteractionModel::Status.constraint_error if delta.to_i32.abs > maximum_delta
        target = @mptz_position.pan.to_i32 + delta.to_i32
        return InteractionModel::Status.constraint_error unless (@pan_min.to_i32..@pan_max.to_i32).includes?(target)
        move_pan(target.to_i16)
      end

      def mptz_move_to_preset(request : MPTZMoveToPresetRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error unless valid_preset_id?(request.preset_id)
        preset = @mptz_presets.find(&.preset_id.==(request.preset_id))
        return InteractionModel::Status.not_found unless preset
        move_pan(preset.settings.pan)
      end

      def mptz_save_preset(request : MPTZSavePresetRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.name.bytesize > MAX_PRESET_NAME_BYTES
        id = request.preset_id
        return InteractionModel::Status.constraint_error if id && !valid_preset_id?(id)
        id ||= (1_u8..@max_presets).find { |candidate| @mptz_presets.none?(&.preset_id.==(candidate)) }
        return InteractionModel::Status.resource_exhausted unless id
        index = @mptz_presets.index(&.preset_id.==(id))
        return InteractionModel::Status.resource_exhausted if !index && @mptz_presets.size >= @max_presets
        preset = MPTZPreset.new(id, request.name, @mptz_position)
        callback = @on_preset_save || return InteractionModel::Status.invalid_in_state
        status = callback.call(preset)
        return status unless status.success?
        updated = @mptz_presets.dup
        if index
          updated[index] = preset
        else
          updated << preset
        end
        self.mptz_presets = updated
        InteractionModel::Status.success
      end

      def mptz_remove_preset(request : MPTZRemovePresetRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error unless valid_preset_id?(request.preset_id)
        index = @mptz_presets.index(&.preset_id.==(request.preset_id))
        return InteractionModel::Status.not_found unless index
        callback = @on_preset_remove || return InteractionModel::Status.invalid_in_state
        status = callback.call(request.preset_id)
        return status unless status.success?
        updated = @mptz_presets.dup
        updated.delete_at(index)
        self.mptz_presets = updated
        InteractionModel::Status.success
      end

      def dptz_set_viewport(request : DPTZSetViewportRequest) : InteractionModel::Status
        source = @video_stream_management || return InteractionModel::Status.invalid_in_state
        index = @dptz_streams.index(&.video_stream_id.==(request.video_stream_id))
        return InteractionModel::Status.not_found unless index
        stream = source.allocated_video_streams.find(&.video_stream_id.==(request.video_stream_id))
        return InteractionModel::Status.not_found unless stream
        viewport = request.viewport
        return InteractionModel::Status.constraint_error unless valid_dptz_viewport?(source, viewport)
        width = viewport.x2.to_u64 - viewport.x1
        height = viewport.y2.to_u64 - viewport.y1
        return InteractionModel::Status.constraint_error unless width * stream.max_resolution.height == height * stream.max_resolution.width
        return InteractionModel::Status.success if @dptz_streams[index].viewport == viewport
        callback = @on_dptz_set_viewport || return InteractionModel::Status.invalid_in_state
        status = callback.call(request.video_stream_id, viewport)
        return status unless status.success?
        updated = @dptz_streams.dup
        updated[index] = DPTZStream.new(request.video_stream_id, viewport)
        self.dptz_streams = updated
        InteractionModel::Status.success
      end

      # Call when the actuator has measured a new position. The final report
      # is persisted and resets MovementState to Idle.
      def report_pan_position(pan : Int16, moving : Bool = false) : Nil
        validate_pan!(pan)
        self.mptz_position = MPTZPosition.new(pan)
        self.movement_state = moving ? PhysicalMovement::Moving : PhysicalMovement::Idle
      end

      private def move_pan(target : Int16) : InteractionModel::Status
        return InteractionModel::Status.constraint_error unless valid_pan?(target)
        actuator = @on_pan_move
        return InteractionModel::Status.invalid_in_state unless actuator
        self.movement_state = PhysicalMovement::Moving
        status = actuator.call(target)
        self.movement_state = PhysicalMovement::Idle unless status.success?
        status
      rescue ex
        self.movement_state = PhysicalMovement::Idle
        raise ex
      end

      private def valid_pan?(pan : Int16) : Bool
        (@pan_min..@pan_max).includes?(pan)
      end

      private def valid_preset_id?(id : UInt8) : Bool
        id > 0_u8 && id <= @max_presets
      end

      private def valid_dptz_viewport?(source : CameraAvStreamManagement,
                                       viewport : CameraAvStreamManagement::Viewport) : Bool
        return false if viewport.x2 <= viewport.x1 || viewport.y2 <= viewport.y1
        sensor = source.video_sensor_params
        minimum = source.min_viewport_resolution
        return false if viewport.x2 > sensor.sensor_width || viewport.y2 > sensor.sensor_height
        viewport.x2 - viewport.x1 >= minimum.width && viewport.y2 - viewport.y1 >= minimum.height
      end

      private def valid_dptz_streams?(streams : Array(DPTZStream)) : Bool
        source = @video_stream_management || return streams.empty?
        active_ids = source.allocated_video_streams.map(&.video_stream_id).to_set
        streams.map(&.video_stream_id).to_set.size == streams.size &&
          streams.all? { |stream| active_ids.includes?(stream.video_stream_id) && valid_dptz_viewport?(source, stream.viewport) }
      end

      private def validate_dptz_streams!(streams : Array(DPTZStream)) : Nil
        raise ArgumentError.new("DPTZStreams contains an unknown stream or invalid viewport") unless valid_dptz_streams?(streams)
      end

      private def remove_dptz_stream(id : UInt16) : Nil
        return unless @dptz_streams.any?(&.video_stream_id.==(id))
        self.dptz_streams = @dptz_streams.reject(&.video_stream_id.==(id))
      end

      private def update_dptz_viewports(viewport : CameraAvStreamManagement::Viewport) : Nil
        return if @dptz_streams.empty?
        self.dptz_streams = @dptz_streams.map { |stream| DPTZStream.new(stream.video_stream_id, viewport) }
      end

      private def valid_presets?(presets : Array(MPTZPreset)) : Bool
        presets.size <= @max_presets &&
          presets.map(&.preset_id).to_set.size == presets.size &&
          presets.all? do |preset|
            valid_preset_id?(preset.preset_id) &&
              preset.name.bytesize <= MAX_PRESET_NAME_BYTES && valid_pan?(preset.settings.pan)
          end
      end

      private def validate_presets!(presets : Array(MPTZPreset)) : Nil
        raise ArgumentError.new("MPTZPresets exceeds capacity or contains invalid settings") unless valid_presets?(presets)
      end

      private def validate_max_presets!(value : UInt8) : Nil
        raise ArgumentError.new("MaxPresets is fixed after construction") unless value == @max_presets
      end

      private def validate_pan!(pan : Int16) : Nil
        raise ArgumentError.new("pan position is outside PanMin/PanMax") unless valid_pan?(pan)
      end

      private def validate_position!(position : MPTZPosition) : Nil
        validate_pan!(position.pan)
      end

      private def validate_pan_min!(value : Int16) : Nil
        unless (PAN_MIN_LIMIT..ZERO_PAN).includes?(value) && value <= @mptz_position.pan
          raise ArgumentError.new("PanMin must be -180..0 and include MPTZPosition")
        end
      end

      private def validate_pan_max!(value : Int16) : Nil
        unless (1_i16..PAN_MAX_LIMIT).includes?(value) && value >= @mptz_position.pan
          raise ArgumentError.new("PanMax must be 1..180 and include MPTZPosition")
        end
      end

      private def after_restore_state : Nil
        self.mptz_position = MPTZPosition.new(ZERO_PAN) unless valid_pan?(@mptz_position.pan)
        self.mptz_presets = [] of MPTZPreset unless valid_presets?(@mptz_presets)
        unless valid_dptz_streams?(@dptz_streams)
          source = @video_stream_management
          active_ids = source ? source.allocated_video_streams.map(&.video_stream_id).to_set : Set(UInt16).new
          seen = Set(UInt16).new
          self.dptz_streams = @dptz_streams.select do |stream|
            if active_ids.includes?(stream.video_stream_id) &&
               !seen.includes?(stream.video_stream_id) &&
               source && valid_dptz_viewport?(source, stream.viewport)
              seen << stream.video_stream_id
              true
            else
              false
            end
          end
        end
        self.movement_state = PhysicalMovement::Idle
      end

      protected def validate_feature_map_change(value : Feature) : Nil
        raise ArgumentError.new("Camera PTZ feature profile is fixed after construction") unless value == @feature_map
      end
    end
  end
end
