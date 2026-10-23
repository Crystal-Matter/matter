require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Zone Management (0x0550). The host supplies motion detections;
    # this server owns zone/trigger configuration, event timing and persistence.
    class ZoneManagement < Base
      cluster 0x0550, revision: 1

      feature :two_d_cartesian_zone, bit: 0
      feature :per_zone_sensitivity, bit: 1
      feature :user_defined, bit: 2
      feature :focus_zones, bit: 3

      MIN_USER_ZONES       =       5_u8
      MIN_SENSITIVITY      =       1_u8
      MIN_SENSITIVITY_MAX  =       2_u8
      MAX_SENSITIVITY_MAX  =      10_u8
      MAX_NAME_BYTES       =         32
      MIN_VERTICES         =          3
      MAX_VERTICES         =         12
      MIN_INITIAL_DURATION =      1_u32
      MAX_INITIAL_DURATION = 65_535_u32
      MAX_ZONE_ID          = 65_534_u16
      LAST_ZONE_ID_KEY     = "last_zone_id"

      enum ZoneType : UInt8
        TwoDCartesian = 0
      end

      enum ZoneSource : UInt8
        Mfg  = 0
        User = 1
      end

      enum ZoneUse : UInt8
        Motion  = 0
        Privacy = 1
        Focus   = 2
      end

      enum TriggeredReason : UInt8
        Motion = 0
      end

      enum StoppedReason : UInt8
        ActionStopped = 0
        Timeout       = 1
      end

      struct Vertex
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter x : UInt16

        @[TLV::Field(tag: 1)]
        getter y : UInt16

        def initialize(@x : UInt16, @y : UInt16)
        end
      end

      struct TwoDCartesianZone
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter name : String

        @[TLV::Field(tag: 1)]
        getter use : ZoneUse

        @[TLV::Field(tag: 2)]
        getter vertices : Array(Vertex)

        @[TLV::Field(tag: 3, optional: true)]
        getter color : String?

        def initialize(@name : String, @use : ZoneUse, @vertices : Array(Vertex), @color : String? = nil)
        end
      end

      struct ZoneInformation
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter zone_id : UInt16

        @[TLV::Field(tag: 1)]
        getter zone_type : ZoneType

        @[TLV::Field(tag: 2)]
        getter source : ZoneSource

        @[TLV::Field(tag: 3)]
        getter two_d_cartesian_zone : TwoDCartesianZone

        def initialize(@zone_id : UInt16, @zone_type : ZoneType,
                       @source : ZoneSource, @two_d_cartesian_zone : TwoDCartesianZone)
        end
      end

      struct Trigger
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter zone_id : UInt16

        @[TLV::Field(tag: 1)]
        getter initial_duration : UInt32

        @[TLV::Field(tag: 2)]
        getter augmentation_duration : UInt32

        @[TLV::Field(tag: 3)]
        getter max_duration : UInt32

        @[TLV::Field(tag: 4)]
        getter blind_duration : UInt32

        @[TLV::Field(tag: 5, optional: true)]
        getter sensitivity : UInt8?

        def initialize(@zone_id : UInt16, @initial_duration : UInt32,
                       @augmentation_duration : UInt32, @max_duration : UInt32,
                       @blind_duration : UInt32, @sensitivity : UInt8? = nil)
        end
      end

      struct CreateZoneRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter zone : TwoDCartesianZone

        def initialize(@zone : TwoDCartesianZone)
        end
      end

      struct CreateZoneResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter zone_id : UInt16

        def initialize(@zone_id : UInt16)
        end
      end

      struct UpdateZoneRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter zone_id : UInt16

        @[TLV::Field(tag: 1)]
        getter zone : TwoDCartesianZone

        def initialize(@zone_id : UInt16, @zone : TwoDCartesianZone)
        end
      end

      struct ZoneIdRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter zone_id : UInt16

        def initialize(@zone_id : UInt16)
        end
      end

      struct TriggerRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter trigger : Trigger

        def initialize(@trigger : Trigger)
        end
      end

      struct ZoneTriggeredEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter zone : UInt16

        @[TLV::Field(tag: 1)]
        getter reason : TriggeredReason

        def initialize(@zone : UInt16, @reason : TriggeredReason)
        end
      end

      struct ZoneStoppedEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter zone : UInt16

        @[TLV::Field(tag: 1)]
        getter reason : StoppedReason

        def initialize(@zone : UInt16, @reason : StoppedReason)
        end
      end

      private record ActiveTrigger,
        started_at : Time::Span,
        detected_until : Time::Span,
        max_until : Time::Span,
        augmented : Bool

      attribute 0x0000, :max_user_defined_zones, UInt8, default: MIN_USER_ZONES,
        fixed: true, requires: :user_defined,
        min: MIN_USER_ZONES
      attribute 0x0001, :max_zones, UInt8, default: MIN_USER_ZONES, fixed: true, min: 1
      attribute 0x0002, :zones, Array(ZoneInformation), default: [] of ZoneInformation,
        persist: true, copy_on_assign: true, validate: :validate_zones!
      attribute 0x0003, :triggers, Array(Trigger), default: [] of Trigger,
        persist: true, copy_on_assign: true, validate: :validate_triggers!
      attribute 0x0004, :sensitivity_max, UInt8, default: 5_u8, fixed: true,
        min: MIN_SENSITIVITY_MAX, max: MAX_SENSITIVITY_MAX
      attribute 0x0005, :sensitivity, UInt8, default: 3_u8,
        writable: true, write_access: :operate, requires: {per_zone_sensitivity: false}
      attribute 0x0006, :two_d_cartesian_max, Vertex, default: Vertex.new(100_u16, 100_u16), fixed: true,
        requires: :two_d_cartesian_zone

      before_write :sensitivity do |value|
        InteractionModel::Status.constraint_error unless (MIN_SENSITIVITY..@sensitivity_max).includes?(value)
      end

      command 0x00, :create_two_d_cartesian_zone, request: CreateZoneRequest,
        response: CreateZoneResponse, response_id: 0x01,
        requires: {two_d_cartesian_zone: true, user_defined: true}, access: :manage
      command 0x02, :update_two_d_cartesian_zone, request: UpdateZoneRequest,
        requires: {two_d_cartesian_zone: true, user_defined: true}, access: :manage
      command 0x03, :remove_zone, request: ZoneIdRequest,
        requires: :user_defined, access: :manage
      command 0x04, :create_or_update_trigger, request: TriggerRequest, access: :manage
      command 0x05, :remove_trigger, request: ZoneIdRequest, access: :manage

      event 0x00, :zone_triggered, priority: :info, payload: ZoneTriggeredEvent
      event 0x01, :zone_stopped, priority: :info, payload: ZoneStoppedEvent

      @trigger_mutex = Mutex.new
      @active = {} of UInt16 => ActiveTrigger
      @blind_until = {} of UInt16 => Time::Span
      @schedule_generation = {} of UInt16 => UInt64
      @last_zone_id : UInt16? = nil
      @zone_change : Proc(ZoneInformation?, ZoneInformation?, InteractionModel::Status)? = nil

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::TwoDCartesianZone | Feature::UserDefined,
                     @max_user_defined_zones : UInt8 = MIN_USER_ZONES,
                     @max_zones : UInt8 = MIN_USER_ZONES,
                     @zones : Array(ZoneInformation) = [] of ZoneInformation,
                     @triggers : Array(Trigger) = [] of Trigger,
                     @sensitivity_max : UInt8 = 5_u8,
                     @sensitivity : UInt8 = 3_u8,
                     @two_d_cartesian_max : Vertex = Vertex.new(100_u16, 100_u16),
                     @automatic_timeouts : Bool = true)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        unless @feature_map == (Feature::TwoDCartesianZone | Feature::UserDefined)
          raise ArgumentError.new("only two-dimensional user-defined zones without per-zone sensitivity are supported")
        end
        raise ArgumentError.new("max_user_defined_zones must be at least five") if @max_user_defined_zones < MIN_USER_ZONES
        mfg_zones = @zones.count(&.source.mfg?)
        if @max_zones.to_i != mfg_zones + @max_user_defined_zones.to_i
          raise ArgumentError.new("max_zones must equal manufacturer zones plus user-defined capacity")
        end
        unless (MIN_SENSITIVITY_MAX..MAX_SENSITIVITY_MAX).includes?(@sensitivity_max)
          raise ArgumentError.new("sensitivity_max must be 2..10")
        end
        unless (MIN_SENSITIVITY..@sensitivity_max).includes?(@sensitivity)
          raise ArgumentError.new("sensitivity must be within supported levels")
        end
        validate_zones!(@zones)
        validate_triggers!(@triggers)
        @last_zone_id = @zones.max_of?(&.zone_id)
      end

      # Camera hosts use this to apply privacy changes before the zone state is
      # committed. Motion-only hosts can omit it.
      def on_zone_change(&block : ZoneInformation?, ZoneInformation? -> InteractionModel::Status) : Nil
        @zone_change = block
      end

      def create_two_d_cartesian_zone(request : CreateZoneRequest) : CreateZoneResponse | InteractionModel::Status
        zone = request.zone
        return InteractionModel::Status.constraint_error unless valid_zone?(zone)
        return InteractionModel::Status.resource_exhausted if @zones.count(&.source.user?) >= @max_user_defined_zones
        return InteractionModel::Status.resource_exhausted if @zones.size >= @max_zones
        id = next_zone_id
        return InteractionModel::Status.resource_exhausted unless id
        new_zone = ZoneInformation.new(id, ZoneType::TwoDCartesian, ZoneSource::User, zone)
        if status = configure_zone(nil, new_zone)
          return status
        end
        self.zones = @zones + [new_zone]
        @last_zone_id = id
        CreateZoneResponse.new(id)
      end

      def update_two_d_cartesian_zone(request : UpdateZoneRequest) : InteractionModel::Status
        existing = @zones.find { |zone| zone.zone_id == request.zone_id }
        return InteractionModel::Status.not_found unless existing
        return InteractionModel::Status.invalid_in_state unless existing.source.user?
        return InteractionModel::Status.constraint_error unless valid_zone?(request.zone)
        new_zone = ZoneInformation.new(existing.zone_id, existing.zone_type, existing.source, request.zone)
        if status = configure_zone(existing, new_zone)
          return status
        end
        self.zones = @zones.map do |zone|
          zone.zone_id == request.zone_id ? new_zone : zone
        end
        if request.zone.use != ZoneUse::Motion
          self.triggers = @triggers.reject { |trigger| trigger.zone_id == request.zone_id }
          clear_active(request.zone_id)
        end
        InteractionModel::Status.success
      end

      def remove_zone(request : ZoneIdRequest) : InteractionModel::Status
        existing = @zones.find { |zone| zone.zone_id == request.zone_id }
        return InteractionModel::Status.not_found unless existing
        return InteractionModel::Status.invalid_in_state unless existing.source.user?
        if status = configure_zone(existing, nil)
          return status
        end
        self.zones = @zones.reject { |zone| zone.zone_id == request.zone_id }
        self.triggers = @triggers.reject { |trigger| trigger.zone_id == request.zone_id }
        clear_active(request.zone_id)
        InteractionModel::Status.success
      end

      def create_or_update_trigger(request : TriggerRequest) : InteractionModel::Status
        trigger = request.trigger
        return InteractionModel::Status.constraint_error unless valid_trigger?(trigger)
        zone = @zones.find { |item| item.zone_id == trigger.zone_id }
        return InteractionModel::Status.not_found unless zone
        return InteractionModel::Status.constraint_error unless zone.two_d_cartesian_zone.use.motion?
        existing = @triggers.any? { |item| item.zone_id == trigger.zone_id }
        return InteractionModel::Status.resource_exhausted if !existing && @triggers.size >= @max_zones
        self.triggers = @triggers.reject { |item| item.zone_id == trigger.zone_id } + [trigger]
        clear_active(trigger.zone_id)
        InteractionModel::Status.success
      end

      def remove_trigger(request : ZoneIdRequest) : InteractionModel::Status
        return InteractionModel::Status.not_found unless @triggers.any? { |item| item.zone_id == request.zone_id }
        self.triggers = @triggers.reject { |item| item.zone_id == request.zone_id }
        clear_active(request.zone_id)
        InteractionModel::Status.success
      end

      # The host calls this when motion is detected. It returns true only for a
      # new trigger, false for an existing or blind trigger.
      def report_motion(zone_id : UInt16, now : Time::Span = Time.monotonic) : Bool
        advance_trigger_timers(now, except: zone_id)
        trigger = @triggers.find { |item| item.zone_id == zone_id }
        return false unless trigger
        started = false
        @trigger_mutex.synchronize do
          if @blind_until[zone_id]?.try { |until_time| now >= until_time } != false
            if active = @active[zone_id]?
              if now < active.max_until && now <= active.detected_until &&
                 (!active.augmented || now >= active.detected_until)
                extended = active.detected_until + trigger.augmentation_duration.to_i64.seconds
                @active[zone_id] = ActiveTrigger.new(active.started_at,
                  {extended, active.max_until}.min, active.max_until, true)
              end
            else
              @active[zone_id] = ActiveTrigger.new(now,
                now + trigger.initial_duration.to_i64.seconds,
                now + trigger.max_duration.to_i64.seconds, false)
              @schedule_generation[zone_id] = (@schedule_generation[zone_id]? || 0_u64) + 1_u64
              started = true
            end
          end
        end
        advance_trigger_timers(now)
        if started
          emit_event(EVENT_ZONE_TRIGGERED, ZoneTriggeredEvent.new(zone_id, TriggeredReason::Motion))
          schedule_timeout(zone_id) if @automatic_timeouts
        end
        started
      end

      # Also useful for deterministic tests and hosts with their own scheduler.
      def advance_trigger_timers(now : Time::Span = Time.monotonic, except : UInt16? = nil) : Nil
        stopped = [] of {UInt16, StoppedReason}
        @trigger_mutex.synchronize do
          @active.each do |id, state|
            next if id == except
            reason = if now >= state.max_until
                       StoppedReason::Timeout
                     elsif now >= state.detected_until
                       StoppedReason::ActionStopped
                     end
            stopped << {id, reason} if reason
          end
          stopped.each do |id, _reason|
            @active.delete(id)
            blind = @triggers.find { |item| item.zone_id == id }.try(&.blind_duration) || 0_u32
            @blind_until[id] = now + blind.to_i64.seconds
          end
        end
        stopped.each do |id, reason|
          emit_event(EVENT_ZONE_STOPPED, ZoneStoppedEvent.new(id, reason))
        end
      end

      private def clear_active(zone_id : UInt16) : Nil
        @trigger_mutex.synchronize do
          @active.delete(zone_id)
          @blind_until.delete(zone_id)
          @schedule_generation[zone_id] = (@schedule_generation[zone_id]? || 0_u64) + 1_u64
        end
      end

      private def schedule_timeout(zone_id : UInt16) : Nil
        generation = @schedule_generation[zone_id]
        spawn do
          loop do
            deadline = @trigger_mutex.synchronize do
              if generation != @schedule_generation[zone_id]?
                nil
              else
                @active[zone_id]?.try { |state| {state.detected_until, state.max_until}.min }
              end
            end
            break unless deadline
            remaining = deadline - Time.monotonic
            sleep remaining if remaining > Time::Span.zero
            advance_trigger_timers
          end
        end
      end

      private def configure_zone(previous : ZoneInformation?, current : ZoneInformation?) : InteractionModel::Status?
        callback = @zone_change
        non_motion = {previous, current}.any? do |entry|
          entry && !entry.two_d_cartesian_zone.use.motion?
        end
        return InteractionModel::Status.invalid_in_state if !callback && non_motion
        return unless callback
        status = callback.call(previous, current)
        status.success? ? nil : status
      end

      private def next_zone_id : UInt16?
        used = @zones.map(&.zone_id).to_set
        start = @last_zone_id || MAX_ZONE_ID
        candidate = start
        (0..MAX_ZONE_ID).each do
          candidate = candidate == MAX_ZONE_ID ? 0_u16 : candidate + 1_u16
          return candidate unless used.includes?(candidate)
        end
        nil
      end

      private def extend_persisted_state(document : Storage::Document) : Nil
        if last_zone_id = @last_zone_id
          document[LAST_ZONE_ID_KEY] = last_zone_id.to_i64
        end
      end

      private def restore_persisted_extension(document : Storage::Document) : Nil
        value = document[LAST_ZONE_ID_KEY]?.as?(Int64)
        @last_zone_id = value.to_u16 if value && (0_i64..MAX_ZONE_ID.to_i64).includes?(value)
      end

      private def after_restore_state : Nil
        @last_zone_id ||= @zones.max_of?(&.zone_id)
      end

      private def validate_zones!(values : Array(ZoneInformation)) : Nil
        raise ArgumentError.new("too many zones") if values.size > @max_zones
        raise ArgumentError.new("duplicate zone ID") if values.map(&.zone_id).uniq!.size != values.size
        raise ArgumentError.new("too many user-defined zones") if values.count(&.source.user?) > @max_user_defined_zones
        values.each do |zone|
          raise ArgumentError.new("zone ID exceeds the Matter range") if zone.zone_id > MAX_ZONE_ID
          raise ArgumentError.new("unsupported zone type or geometry") unless zone.zone_type.two_d_cartesian? && valid_zone?(zone.two_d_cartesian_zone)
        end
      end

      private def validate_triggers!(values : Array(Trigger)) : Nil
        raise ArgumentError.new("too many triggers") if values.size > @max_zones
        raise ArgumentError.new("duplicate trigger zone ID") if values.map(&.zone_id).uniq!.size != values.size
        values.each do |trigger|
          raise ArgumentError.new("invalid trigger") unless valid_trigger?(trigger)
          zone = @zones.find { |item| item.zone_id == trigger.zone_id }
          raise ArgumentError.new("trigger references a non-motion zone") unless zone && zone.two_d_cartesian_zone.use.motion?
        end
      end

      private def valid_trigger?(trigger : Trigger) : Bool
        trigger.initial_duration >= MIN_INITIAL_DURATION &&
          trigger.initial_duration <= MAX_INITIAL_DURATION &&
          trigger.augmentation_duration <= trigger.initial_duration &&
          trigger.max_duration >= trigger.initial_duration &&
          trigger.sensitivity.nil?
      end

      private def valid_zone?(zone : TwoDCartesianZone) : Bool
        return false if zone.name.bytesize > MAX_NAME_BYTES
        return false if zone.use.focus?
        if color = zone.color
          return false unless /\A\#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?\z/.matches?(color)
        end
        vertices = zone.vertices
        return false unless (MIN_VERTICES..MAX_VERTICES).includes?(vertices.size)
        return false if vertices.any? { |vertex| vertex.x > @two_d_cartesian_max.x || vertex.y > @two_d_cartesian_max.y }
        return false if vertices.uniq.size != vertices.size
        return false if polygon_area_twice(vertices) == 0_i64
        !self_intersecting?(vertices)
      end

      private def polygon_area_twice(vertices : Array(Vertex)) : Int64
        area = 0_i64
        vertices.each_index do |index|
          current = vertices[index]
          following = vertices[(index + 1) % vertices.size]
          area += current.x.to_i64 * following.y - following.x.to_i64 * current.y
        end
        area
      end

      private def self_intersecting?(vertices : Array(Vertex)) : Bool
        count = vertices.size
        (0...count).each do |first|
          ((first + 1)...count).each do |second|
            next if second == first + 1 || (first == 0 && second == count - 1)
            a = vertices[first]
            b = vertices[(first + 1) % count]
            c = vertices[second]
            d = vertices[(second + 1) % count]
            return true if segments_intersect?(a, b, c, d)
          end
        end
        false
      end

      private def segments_intersect?(a : Vertex, b : Vertex, c : Vertex, d : Vertex) : Bool
        ab_c = orientation(a, b, c)
        ab_d = orientation(a, b, d)
        cd_a = orientation(c, d, a)
        cd_b = orientation(c, d, b)
        return true if ab_c == 0_i64 && on_segment?(a, b, c)
        return true if ab_d == 0_i64 && on_segment?(a, b, d)
        return true if cd_a == 0_i64 && on_segment?(c, d, a)
        return true if cd_b == 0_i64 && on_segment?(c, d, b)
        (ab_c > 0) != (ab_d > 0) && (cd_a > 0) != (cd_b > 0)
      end

      private def orientation(a : Vertex, b : Vertex, c : Vertex) : Int64
        (b.x.to_i64 - a.x) * (c.y.to_i64 - a.y) - (b.y.to_i64 - a.y) * (c.x.to_i64 - a.x)
      end

      private def on_segment?(a : Vertex, b : Vertex, c : Vertex) : Bool
        c.x >= {a.x, b.x}.min && c.x <= {a.x, b.x}.max &&
          c.y >= {a.y, b.y}.min && c.y <= {a.y, b.y}.max
      end
    end
  end
end
