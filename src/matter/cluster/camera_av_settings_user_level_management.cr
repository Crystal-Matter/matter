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
      feature :mechanical_tilt, bit: 2
      feature :mechanical_zoom, bit: 3
      feature :mechanical_presets, bit: 4

      PAN_MIN_LIMIT         = -180_i16
      PAN_MAX_LIMIT         =  180_i16
      TILT_MIN_LIMIT        = -180_i16
      TILT_MAX_LIMIT        =  180_i16
      ZERO_PAN              =    0_i16
      ZERO_TILT             =    0_i16
      MIN_ZOOM              =     1_u8
      MAX_ZOOM_LIMIT        =   100_u8
      MAX_PRESET_NAME_BYTES =       32

      enum PhysicalMovement : UInt8
        Idle   = 0
        Moving = 1
      end

      struct MPTZPosition
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0, optional: true)]
        getter pan : Int16?

        @[TLV::Field(tag: 1, optional: true)]
        getter tilt : Int16?

        @[TLV::Field(tag: 2, optional: true)]
        getter zoom : UInt8?

        def initialize(@pan : Int16? = nil, @tilt : Int16? = nil, @zoom : UInt8? = nil)
        end
      end

      struct MPTZSetPositionRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter pan : Int16?

        @[TLV::Field(tag: 1, optional: true)]
        getter tilt : Int16?

        @[TLV::Field(tag: 2, optional: true)]
        getter zoom : UInt8?

        def initialize(@pan : Int16? = nil, @tilt : Int16? = nil, @zoom : UInt8? = nil)
        end
      end

      struct MPTZRelativeMoveRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter pan_delta : Int16?

        @[TLV::Field(tag: 1, optional: true)]
        getter tilt_delta : Int16?

        @[TLV::Field(tag: 2, optional: true)]
        getter zoom_delta : Int8?

        def initialize(@pan_delta : Int16? = nil, @tilt_delta : Int16? = nil, @zoom_delta : Int8? = nil)
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
        default: MPTZPosition.new, persist: true,
        requires: [{mechanical_pan: true}, {mechanical_tilt: true}, {mechanical_zoom: true}],
        validate: :validate_position!
      attribute 0x0001, :max_presets, UInt8, default: 0_u8,
        fixed: true, requires: :mechanical_presets, validate: :validate_max_presets!
      attribute 0x0002, :mptz_presets, Array(MPTZPreset), default: [] of MPTZPreset,
        persist: true, persist_default: [] of MPTZPreset, requires: :mechanical_presets,
        copy_on_assign: true, copy_on_read: true, validate: :validate_presets!
      attribute 0x0003, :dptz_streams, Array(DPTZStream), default: [] of DPTZStream,
        persist: true, persist_default: [] of DPTZStream, requires: :digital_ptz,
        copy_on_assign: true, copy_on_read: true, validate: :validate_dptz_streams!
      attribute 0x0004, :zoom_max, UInt8, default: MAX_ZOOM_LIMIT,
        requires: :mechanical_zoom, validate: :validate_zoom_max!
      attribute 0x0005, :tilt_min, Int16, default: TILT_MIN_LIMIT,
        requires: :mechanical_tilt, validate: :validate_tilt_min!
      attribute 0x0006, :tilt_max, Int16, default: TILT_MAX_LIMIT,
        requires: :mechanical_tilt, validate: :validate_tilt_max!
      attribute 0x0007, :pan_min, Int16, default: PAN_MIN_LIMIT,
        requires: :mechanical_pan, validate: :validate_pan_min!
      attribute 0x0008, :pan_max, Int16, default: PAN_MAX_LIMIT,
        requires: :mechanical_pan, validate: :validate_pan_max!
      attribute 0x0009, :movement_state, PhysicalMovement,
        default: PhysicalMovement::Idle,
        requires: [{mechanical_pan: true}, {mechanical_tilt: true}, {mechanical_zoom: true}]

      command 0x00, :mptz_set_position, request: MPTZSetPositionRequest,
        access: :operate, requires: [{mechanical_pan: true}, {mechanical_tilt: true}, {mechanical_zoom: true}]
      command 0x01, :mptz_relative_move, request: MPTZRelativeMoveRequest,
        access: :operate, requires: [{mechanical_pan: true}, {mechanical_tilt: true}, {mechanical_zoom: true}]
      command 0x02, :mptz_move_to_preset, request: MPTZMoveToPresetRequest,
        access: :operate, requires: :mechanical_presets
      command 0x03, :mptz_save_preset, request: MPTZSavePresetRequest,
        access: :operate, requires: :mechanical_presets
      command 0x04, :mptz_remove_preset, request: MPTZRemovePresetRequest,
        access: :operate, requires: :mechanical_presets
      command 0x05, :dptz_set_viewport, request: DPTZSetViewportRequest,
        access: :operate, requires: :digital_ptz

      @on_pan_move : Proc(Int16, InteractionModel::Status)?
      @on_mptz_move : Proc(MPTZPosition, InteractionModel::Status)?
      @on_preset_save : Proc(MPTZPreset, InteractionModel::Status)?
      @on_preset_remove : Proc(UInt8, InteractionModel::Status)?
      @on_dptz_set_viewport : Proc(UInt16, CameraAvStreamManagement::Viewport, InteractionModel::Status)?
      @video_stream_management : CameraAvStreamManagement?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @pan_min : Int16 = PAN_MIN_LIMIT,
                     @pan_max : Int16 = PAN_MAX_LIMIT,
                     initial_pan : Int16 = ZERO_PAN,
                     @tilt_min : Int16 = TILT_MIN_LIMIT,
                     @tilt_max : Int16 = TILT_MAX_LIMIT,
                     initial_tilt : Int16 = ZERO_TILT,
                     @zoom_max : UInt8 = MAX_ZOOM_LIMIT,
                     initial_zoom : UInt8 = MIN_ZOOM,
                     @max_presets : UInt8 = 0_u8,
                     video_stream_management : CameraAvStreamManagement? = nil,
                     @feature_map : Feature = Feature::MechanicalPan)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        mechanical = Feature::MechanicalPan | Feature::MechanicalTilt | Feature::MechanicalZoom
        if @feature_map.digital_ptz?
          raise ArgumentError.new("DigitalPTZ combinations are not implemented") unless @feature_map == Feature::DigitalPtz
        elsif (@feature_map.value & mechanical.value).zero? ||
              (@feature_map.value & ~(mechanical | Feature::MechanicalPresets).value) != 0
          raise ArgumentError.new("unsupported mechanical PTZ feature profile")
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
        unless (TILT_MIN_LIMIT..ZERO_TILT).includes?(@tilt_min) &&
               (1_i16..TILT_MAX_LIMIT).includes?(@tilt_max)
          raise ArgumentError.new("tilt limits must be -180..0 and 1..180")
        end
        raise ArgumentError.new("ZoomMax must be 2..100") unless @zoom_max.in?(2_u8..MAX_ZOOM_LIMIT)
        position = MPTZPosition.new(
          @feature_map.mechanical_pan? ? initial_pan : nil,
          @feature_map.mechanical_tilt? ? initial_tilt : nil,
          @feature_map.mechanical_zoom? ? initial_zoom : nil)
        validate_position!(position)
        @mptz_position = position
      end

      # The callback starts physical movement to target and returns the
      # command status. Report completion with #report_pan_position.
      def on_pan_move(&block : Int16 -> InteractionModel::Status) : Nil
        @on_pan_move = block
      end

      # Required for any profile with tilt or zoom. The host starts movement
      # to the complete target and later reports measured position.
      def on_mptz_move(&block : MPTZPosition -> InteractionModel::Status) : Nil
        @on_mptz_move = block
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
        return InteractionModel::Status.constraint_error if request.pan.nil? && request.tilt.nil? && request.zoom.nil?
        return InteractionModel::Status.invalid_command if !request.pan.nil? && !@feature_map.mechanical_pan?
        return InteractionModel::Status.invalid_command if !request.tilt.nil? && !@feature_map.mechanical_tilt?
        return InteractionModel::Status.invalid_command if !request.zoom.nil? && !@feature_map.mechanical_zoom?
        target = MPTZPosition.new(request.pan || @mptz_position.pan,
          request.tilt || @mptz_position.tilt, request.zoom || @mptz_position.zoom)
        move_mptz(target)
      end

      def mptz_relative_move(request : MPTZRelativeMoveRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.pan_delta.nil? && request.tilt_delta.nil? && request.zoom_delta.nil?
        return InteractionModel::Status.invalid_command if !request.pan_delta.nil? && !@feature_map.mechanical_pan?
        return InteractionModel::Status.invalid_command if !request.tilt_delta.nil? && !@feature_map.mechanical_tilt?
        return InteractionModel::Status.invalid_command if !request.zoom_delta.nil? && !@feature_map.mechanical_zoom?
        if delta = request.pan_delta
          return InteractionModel::Status.constraint_error if delta.to_i32.abs > @pan_max.to_i32 - @pan_min.to_i32
        end
        if delta = request.tilt_delta
          return InteractionModel::Status.constraint_error if delta.to_i32.abs > @tilt_max.to_i32 - @tilt_min.to_i32
        end
        if delta = request.zoom_delta
          return InteractionModel::Status.constraint_error if delta.to_i32.abs > @zoom_max.to_i32 - MIN_ZOOM
        end
        pan = @mptz_position.pan.try(&.to_i32) || ZERO_PAN.to_i32
        tilt = @mptz_position.tilt.try(&.to_i32) || ZERO_TILT.to_i32
        zoom = @mptz_position.zoom.try(&.to_i32) || MIN_ZOOM.to_i32
        pan += request.pan_delta.try(&.to_i32) || 0
        tilt += request.tilt_delta.try(&.to_i32) || 0
        zoom += request.zoom_delta.try(&.to_i32) || 0
        return InteractionModel::Status.constraint_error if @feature_map.mechanical_pan? && !(@pan_min.to_i32..@pan_max.to_i32).includes?(pan)
        return InteractionModel::Status.constraint_error if @feature_map.mechanical_tilt? && !(@tilt_min.to_i32..@tilt_max.to_i32).includes?(tilt)
        return InteractionModel::Status.constraint_error if @feature_map.mechanical_zoom? && !(MIN_ZOOM.to_i32..@zoom_max.to_i32).includes?(zoom)
        target = MPTZPosition.new(
          @feature_map.mechanical_pan? ? pan.to_i16 : nil,
          @feature_map.mechanical_tilt? ? tilt.to_i16 : nil,
          @feature_map.mechanical_zoom? ? zoom.to_u8 : nil)
        move_mptz(target)
      end

      def mptz_move_to_preset(request : MPTZMoveToPresetRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error unless valid_preset_id?(request.preset_id)
        preset = @mptz_presets.find(&.preset_id.==(request.preset_id))
        return InteractionModel::Status.not_found unless preset
        move_mptz(preset.settings)
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
        report_mptz_position(MPTZPosition.new(pan, @mptz_position.tilt, @mptz_position.zoom), moving)
      end

      def report_mptz_position(position : MPTZPosition, moving : Bool = false) : Nil
        validate_position!(position)
        self.mptz_position = position
        self.movement_state = moving ? PhysicalMovement::Moving : PhysicalMovement::Idle
      end

      private def move_mptz(target : MPTZPosition) : InteractionModel::Status
        return InteractionModel::Status.constraint_error unless valid_position?(target)
        actuator = @on_mptz_move
        pan_actuator = @on_pan_move if @feature_map.mechanical_pan? && !@feature_map.mechanical_tilt? && !@feature_map.mechanical_zoom?
        return InteractionModel::Status.invalid_in_state unless actuator || pan_actuator
        self.movement_state = PhysicalMovement::Moving
        status = actuator ? actuator.call(target) : pan_actuator.as(Proc(Int16, InteractionModel::Status)).call(target.pan.as(Int16))
        self.movement_state = PhysicalMovement::Idle unless status.success?
        status
      rescue ex
        self.movement_state = PhysicalMovement::Idle
        raise ex
      end

      private def valid_pan?(pan : Int16) : Bool
        (@pan_min..@pan_max).includes?(pan)
      end

      private def valid_position?(position : MPTZPosition) : Bool
        return false if @feature_map.mechanical_pan? == position.pan.nil?
        return false if @feature_map.mechanical_tilt? == position.tilt.nil?
        return false if @feature_map.mechanical_zoom? == position.zoom.nil?
        return false if (pan = position.pan) && !valid_pan?(pan)
        return false if (tilt = position.tilt) && !(@tilt_min..@tilt_max).includes?(tilt)
        return false if (zoom = position.zoom) && !(MIN_ZOOM..@zoom_max).includes?(zoom)
        true
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
              preset.name.bytesize <= MAX_PRESET_NAME_BYTES && valid_position?(preset.settings)
          end
      end

      private def validate_presets!(presets : Array(MPTZPreset)) : Nil
        raise ArgumentError.new("MPTZPresets exceeds capacity or contains invalid settings") unless valid_presets?(presets)
      end

      private def validate_max_presets!(value : UInt8) : Nil
        raise ArgumentError.new("MaxPresets is fixed after construction") unless value == @max_presets
      end

      private def validate_position!(position : MPTZPosition) : Nil
        raise ArgumentError.new("MPTZ position is outside feature limits") unless valid_position?(position)
      end

      private def validate_pan_min!(value : Int16) : Nil
        pan = @mptz_position.pan || ZERO_PAN
        unless (PAN_MIN_LIMIT..ZERO_PAN).includes?(value) && value <= pan &&
               @mptz_presets.all? { |preset| (saved_pan = preset.settings.pan) && value <= saved_pan }
          raise ArgumentError.new("PanMin must be -180..0 and include MPTZPosition")
        end
      end

      private def validate_pan_max!(value : Int16) : Nil
        pan = @mptz_position.pan || ZERO_PAN
        unless (1_i16..PAN_MAX_LIMIT).includes?(value) && value >= pan &&
               @mptz_presets.all? { |preset| (saved_pan = preset.settings.pan) && value >= saved_pan }
          raise ArgumentError.new("PanMax must be 1..180 and include MPTZPosition")
        end
      end

      private def validate_tilt_min!(value : Int16) : Nil
        tilt = @mptz_position.tilt || ZERO_TILT
        unless (TILT_MIN_LIMIT..ZERO_TILT).includes?(value) && value <= tilt &&
               @mptz_presets.all? { |preset| (saved_tilt = preset.settings.tilt) && value <= saved_tilt }
          raise ArgumentError.new("TiltMin must be -180..0 and include MPTZPosition and presets")
        end
      end

      private def validate_tilt_max!(value : Int16) : Nil
        tilt = @mptz_position.tilt || ZERO_TILT
        unless (1_i16..TILT_MAX_LIMIT).includes?(value) && value >= tilt &&
               @mptz_presets.all? { |preset| (saved_tilt = preset.settings.tilt) && value >= saved_tilt }
          raise ArgumentError.new("TiltMax must be 1..180 and include MPTZPosition and presets")
        end
      end

      private def validate_zoom_max!(value : UInt8) : Nil
        zoom = @mptz_position.zoom || MIN_ZOOM
        unless (2_u8..MAX_ZOOM_LIMIT).includes?(value) && value >= zoom &&
               @mptz_presets.all? { |preset| (saved_zoom = preset.settings.zoom) && value >= saved_zoom }
          raise ArgumentError.new("ZoomMax must be 2..100 and include MPTZPosition and presets")
        end
      end

      private def after_restore_state : Nil
        unless valid_position?(@mptz_position)
          self.mptz_position = MPTZPosition.new(
            @feature_map.mechanical_pan? ? ZERO_PAN : nil,
            @feature_map.mechanical_tilt? ? ZERO_TILT : nil,
            @feature_map.mechanical_zoom? ? MIN_ZOOM : nil)
        end
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
