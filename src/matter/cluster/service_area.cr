require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Service Area. The host owns the available areas and physical
    # route decisions; this cluster owns the selected-area protocol state.
    class ServiceArea < Base
      cluster 0x0150, revision: 2

      feature :select_while_running, bit: 0
      feature :progress_reporting, bit: 1
      feature :maps, bit: 2

      MAX_AREAS             = 255
      MAX_MAPS              = 255
      MAX_LOCATION_BYTES    = 128
      MAX_MAP_NAME_BYTES    =  64
      MAX_STATUS_TEXT_BYTES = 256

      enum SelectAreasStatus : UInt8
        Success
        UnsupportedArea
        InvalidInMode
        InvalidSet
      end

      enum SkipAreaStatus : UInt8
        Success
        InvalidAreaList
        InvalidInMode
        InvalidSkippedArea
      end

      enum OperationalStatus : UInt8
        Pending
        Operating
        Skipped
        Completed
      end

      struct LocationInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter location_name : String

        @[TLV::Field(tag: 1)]
        getter floor_number : Int16?

        @[TLV::Field(tag: 2)]
        getter area_type : UInt8?

        def initialize(@location_name : String, @floor_number : Int16? = nil, @area_type : UInt8? = nil)
          raise ArgumentError.new("location name exceeds #{MAX_LOCATION_BYTES} bytes") if @location_name.bytesize > MAX_LOCATION_BYTES
        end
      end

      struct LandmarkInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter landmark_tag : UInt8

        @[TLV::Field(tag: 1)]
        getter relative_position_tag : UInt8?

        def initialize(@landmark_tag : UInt8, @relative_position_tag : UInt8? = nil)
        end
      end

      struct AreaInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter location_info : LocationInfo?

        @[TLV::Field(tag: 1)]
        getter landmark_info : LandmarkInfo?

        def initialize(@location_info : LocationInfo? = nil, @landmark_info : LandmarkInfo? = nil)
          meaningful = @landmark_info || @location_info.try do |location|
            !location.location_name.empty? || !location.floor_number.nil? || !location.area_type.nil?
          end
          raise ArgumentError.new("AreaInfo requires a name or semantic data") unless meaningful
        end
      end

      struct Area
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter area_id : UInt32

        @[TLV::Field(tag: 1)]
        getter map_id : UInt32?

        @[TLV::Field(tag: 2)]
        getter area_info : AreaInfo

        def initialize(@area_id : UInt32, @map_id : UInt32?, @area_info : AreaInfo)
        end
      end

      struct MapInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter map_id : UInt32

        @[TLV::Field(tag: 1)]
        getter name : String

        def initialize(@map_id : UInt32, @name : String)
          raise ArgumentError.new("map name exceeds #{MAX_MAP_NAME_BYTES} bytes") if @name.bytesize > MAX_MAP_NAME_BYTES
        end
      end

      struct ProgressInfo
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter area_id : UInt32

        @[TLV::Field(tag: 1)]
        getter status : OperationalStatus

        @[TLV::Field(tag: 2, optional: true)]
        getter total_operational_time : UInt32?

        @[TLV::Field(tag: 3, optional: true)]
        getter estimated_time : UInt32?

        def initialize(@area_id : UInt32, @status : OperationalStatus,
                       @total_operational_time : UInt32? = nil, @estimated_time : UInt32? = nil)
          if @total_operational_time && !@status.in?(OperationalStatus::Skipped, OperationalStatus::Completed)
            raise ArgumentError.new("TotalOperationalTime requires Skipped or Completed status")
          end
        end
      end

      struct SelectAreasRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter new_areas : Array(UInt32)

        def initialize(@new_areas : Array(UInt32))
        end
      end

      struct SelectAreasResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter status : SelectAreasStatus

        @[TLV::Field(tag: 1)]
        getter status_text : String

        def initialize(@status : SelectAreasStatus, @status_text : String = "")
          raise ArgumentError.new("status text exceeds #{MAX_STATUS_TEXT_BYTES} bytes") if @status_text.bytesize > MAX_STATUS_TEXT_BYTES
          if @status.in?(SelectAreasStatus::InvalidInMode, SelectAreasStatus::InvalidSet) && @status_text.empty?
            raise ArgumentError.new("status text is required for this error")
          end
        end
      end

      struct SkipAreaRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter skipped_area : UInt32

        def initialize(@skipped_area : UInt32)
        end
      end

      struct SkipAreaResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter status : SkipAreaStatus

        @[TLV::Field(tag: 1)]
        getter status_text : String

        def initialize(@status : SkipAreaStatus, @status_text : String = "")
          raise ArgumentError.new("status text exceeds #{MAX_STATUS_TEXT_BYTES} bytes") if @status_text.bytesize > MAX_STATUS_TEXT_BYTES
        end
      end

      attribute 0x0000, :supported_areas, Array(Area), default: [] of Area,
        fixed: true, validate: :reject_direct_catalogue!, copy_on_assign: true
      attribute 0x0001, :supported_maps, Array(MapInfo), default: [] of MapInfo,
        fixed: true, requires: :maps, validate: :reject_direct_maps!, copy_on_assign: true
      attribute 0x0002, :selected_areas, Array(UInt32), default: [] of UInt32,
        persist: true, copy_on_assign: true, validate: :validate_selected_areas!
      attribute 0x0003, :current_area, UInt32, nullable: true, optional: true,
        present_if: :current_area_present?, validate: :validate_current_area!,
        on_change: :reconcile_current_area
      attribute 0x0004, :estimated_end_time, UInt32, nullable: true, optional: true,
        present_if: :estimated_end_time_present?, computed: true
      attribute 0x0005, :progress, Array(ProgressInfo), default: [] of ProgressInfo,
        requires: :progress_reporting, copy_on_assign: true, validate: :validate_progress!

      command 0x00, :select_areas, request: SelectAreasRequest,
        response: SelectAreasResponse, response_id: 0x01, access: :operate
      command 0x02, :skip_area, request: SkipAreaRequest,
        response: SkipAreaResponse, response_id: 0x03, access: :operate,
        present_if: :skip_area_supported?, optional: true

      @on_select : Proc(Array(UInt32), SelectAreasResponse)? = nil
      @on_operating : Proc(Bool)? = nil
      @on_skip : Proc(UInt32, SkipAreaResponse)? = nil
      @current_area_present : Bool
      @estimated_end_time_present : Bool
      @skip_enabled : Bool

      def initialize(endpoint_id : DataType::EndpointNumber,
                     areas : Array(Area), maps : Array(MapInfo) = [] of MapInfo,
                     selected_areas : Array(UInt32) = [] of UInt32,
                     current_area : UInt32? = nil, reports_current_area : Bool = false,
                     estimated_end_time : UInt32? = nil, report_estimated_end_time : Bool = false,
                     skip_enabled : Bool = false,
                     @feature_map : Feature = Feature::None)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_catalogue!(areas, maps)
        @supported_areas = areas.dup
        @supported_maps = maps.dup
        @selected_areas = selected_areas.dup
        validate_selected_areas!(@selected_areas)
        @current_area_present = reports_current_area
        @current_area = current_area
        validate_current_area!(@current_area)
        @estimated_end_time_present = report_estimated_end_time
        @estimated_end_time = estimated_end_time
        validate_estimated_end_time!(@estimated_end_time)
        @progress = [] of ProgressInfo
        @skip_enabled = skip_enabled
        raise ArgumentError.new("CurrentArea is not enabled") if current_area && !reports_current_area
        raise ArgumentError.new("EstimatedEndTime requires CurrentArea") if report_estimated_end_time && !reports_current_area
        raise ArgumentError.new("EstimatedEndTime is not enabled") if estimated_end_time && !report_estimated_end_time
        raise ArgumentError.new("SkipArea requires CurrentArea or Progress") if skip_enabled && !reports_current_area && !@feature_map.progress_reporting?
      end

      def on_select(&block : Array(UInt32) -> SelectAreasResponse) : Nil
        @on_select = block
      end

      def on_operating(&block : -> Bool) : Nil
        @on_operating = block
      end

      def on_skip(&block : UInt32 -> SkipAreaResponse) : Nil
        @on_skip = block
      end

      def supported_areas : Array(Area)
        @supported_areas.dup
      end

      def supported_maps : Array(MapInfo)
        @supported_maps.dup
      end

      def selected_areas : Array(UInt32)
        @selected_areas.dup
      end

      def progress : Array(ProgressInfo)
        @progress.dup
      end

      def estimated_end_time : UInt32?
        @current_area.nil? ? nil : @estimated_end_time
      end

      # Matter restricts EstimatedEndTime reports to decreases and transitions
      # involving zero or null. Increases still advance DataVersion for reads.
      def report_estimated_end_time(value : UInt32?) : Nil
        raise ArgumentError.new("EstimatedEndTime is not supported") unless @estimated_end_time_present
        validate_estimated_end_time!(value)
        previous = @estimated_end_time
        return if previous == value
        @estimated_end_time = value
        if previous.nil? || value.nil? || previous == 0_u32 || value == 0_u32 ||
           (previous && value && value < previous)
          increment_version_and_notify(ATTR_ESTIMATED_END_TIME)
        else
          increment_version
        end
      end

      # The host calls this when an operation begins. A constrained selection
      # gets exactly one Pending progress entry per selected area.
      def begin_operation : Nil
        return unless @feature_map.progress_reporting?
        return if @selected_areas.empty?
        self.progress = @selected_areas.map { |id| ProgressInfo.new(id, OperationalStatus::Pending) }
      end

      # An unexpected stop must not leave Pending or Operating entries behind.
      def end_operation_unexpectedly : Nil
        return unless @feature_map.progress_reporting?
        self.progress = @progress.map do |entry|
          if entry.status.in?(OperationalStatus::Pending, OperationalStatus::Operating)
            ProgressInfo.new(entry.area_id, OperationalStatus::Skipped)
          else
            entry
          end
        end
      end

      def select_areas(request : SelectAreasRequest) : SelectAreasResponse
        selected = request.new_areas.uniq
        return SelectAreasResponse.new(SelectAreasStatus::UnsupportedArea) unless selected.all? { |id| area_present?(id) }
        return SelectAreasResponse.new(SelectAreasStatus::Success) if selected == @selected_areas
        if !@feature_map.select_while_running? && @on_operating.try(&.call)
          return SelectAreasResponse.new(SelectAreasStatus::InvalidInMode, "Area selection is unavailable while operating")
        end
        result = @on_select.try(&.call(selected.dup)) || SelectAreasResponse.new(SelectAreasStatus::Success)
        self.selected_areas = selected if result.status.success?
        result
      end

      def skip_area(request : SkipAreaRequest) : SkipAreaResponse
        return SkipAreaResponse.new(SkipAreaStatus::InvalidAreaList) if @selected_areas.empty?
        return SkipAreaResponse.new(SkipAreaStatus::InvalidSkippedArea) unless area_present?(request.skipped_area)
        return SkipAreaResponse.new(SkipAreaStatus::InvalidInMode) unless @selected_areas.includes?(request.skipped_area)
        callback = @on_skip
        return SkipAreaResponse.new(SkipAreaStatus::InvalidInMode) unless callback
        result = callback.call(request.skipped_area)
        if result.status.success? && @feature_map.progress_reporting?
          updated = @progress.map do |entry|
            entry.area_id == request.skipped_area ? ProgressInfo.new(entry.area_id, OperationalStatus::Skipped) : entry
          end
          self.progress = updated
        end
        result
      end

      def update_areas(areas : Array(Area)) : Nil
        update_catalogue(areas, @supported_maps)
      end

      def update_maps(maps : Array(MapInfo)) : Nil
        raise ArgumentError.new("Maps feature is required") unless @feature_map.maps?
        ids = maps.map(&.map_id)
        areas = @supported_areas.select { |area| area.map_id && ids.includes?(area.map_id.as(UInt32)) }
        update_catalogue(areas, maps)
      end

      def update_catalogue(areas : Array(Area), maps : Array(MapInfo) = [] of MapInfo) : Nil
        validate_catalogue!(areas, maps)
        old_areas = @supported_areas
        old_maps = @supported_maps
        old_selected = @selected_areas
        old_current = @current_area
        old_progress = @progress
        old_end_time = @estimated_end_time
        valid_ids = areas.map(&.area_id)
        @supported_areas = areas.dup
        @supported_maps = maps.dup
        @selected_areas = old_selected.select { |id| valid_ids.includes?(id) }
        @current_area = nil if old_current && !valid_ids.includes?(old_current)
        @progress = old_progress.select { |entry| valid_ids.includes?(entry.area_id) }
        @estimated_end_time = nil if @current_area.nil?

        increment_version_and_notify(ATTR_SUPPORTED_MAPS) if @feature_map.maps? && old_maps != maps
        increment_version_and_notify(ATTR_SUPPORTED_AREAS) if old_areas != areas
        increment_version_and_notify(ATTR_SELECTED_AREAS) if old_selected != @selected_areas
        increment_version_and_notify(ATTR_CURRENT_AREA) if @current_area_present && old_current != @current_area
        increment_version_and_notify(ATTR_PROGRESS) if @feature_map.progress_reporting? && old_progress != @progress
        if @estimated_end_time_present && old_end_time != @estimated_end_time
          increment_version_and_notify(ATTR_ESTIMATED_END_TIME)
        end
        @on_supported_maps_changed.try &.call(old_maps, @supported_maps) if old_maps != @supported_maps
        @on_supported_areas_changed.try &.call(old_areas, @supported_areas) if old_areas != @supported_areas
        @on_selected_areas_changed.try &.call(old_selected, @selected_areas) if old_selected != @selected_areas
        @on_current_area_changed.try &.call(old_current, @current_area) if old_current != @current_area
        @on_progress_changed.try &.call(old_progress, @progress) if old_progress != @progress
      end

      private def current_area_present? : Bool
        @current_area_present
      end

      private def estimated_end_time_present? : Bool
        @estimated_end_time_present
      end

      private def skip_area_supported?(_command_id : UInt32) : Bool
        @skip_enabled
      end

      private def area_present?(id : UInt32) : Bool
        @supported_areas.any?(&.area_id.==(id))
      end

      private def validate_catalogue!(areas : Array(Area), maps : Array(MapInfo)) : Nil
        raise ArgumentError.new("SupportedAreas exceeds #{MAX_AREAS} entries") if areas.size > MAX_AREAS
        raise ArgumentError.new("SupportedMaps exceeds #{MAX_MAPS} entries") if maps.size > MAX_MAPS
        raise ArgumentError.new("Maps feature is required") if !@feature_map.maps? && !maps.empty?
        raise ArgumentError.new("duplicate AreaID") unless areas.map(&.area_id).uniq!.size == areas.size
        raise ArgumentError.new("duplicate MapID") unless maps.map(&.map_id).uniq!.size == maps.size
        raise ArgumentError.new("duplicate map name") unless maps.map(&.name).uniq!.size == maps.size
        raise ArgumentError.new("duplicate AreaInfo within a map") unless areas.map { |area| {area.map_id, area.area_info} }.uniq!.size == areas.size
        areas.each do |area|
          if maps.empty?
            raise ArgumentError.new("MapID requires SupportedMaps") unless area.map_id.nil?
          else
            raise ArgumentError.new("Area MapID is absent from SupportedMaps") unless maps.any?(&.map_id.==(area.map_id))
          end
        end
      end

      private def validate_selected_areas!(selected : Array(UInt32)) : Nil
        raise ArgumentError.new("duplicate selected area") unless selected.uniq.size == selected.size
        raise ArgumentError.new("selected area is unsupported") unless selected.all? { |id| area_present?(id) }
      end

      private def validate_current_area!(area : UInt32?) : Nil
        raise ArgumentError.new("CurrentArea is unsupported") if area && !area_present?(area)
      end

      private def validate_estimated_end_time!(time : UInt32?) : Nil
        raise ArgumentError.new("EstimatedEndTime requires CurrentArea") if time && @current_area.nil?
      end

      private def reconcile_current_area(value : UInt32?) : Nil
        report_estimated_end_time(nil) if value.nil? && @estimated_end_time_present
      end

      private def validate_progress!(items : Array(ProgressInfo)) : Nil
        raise ArgumentError.new("Progress exceeds #{MAX_AREAS} entries") if items.size > MAX_AREAS
        raise ArgumentError.new("duplicate Progress AreaID") unless items.map(&.area_id).uniq!.size == items.size
        raise ArgumentError.new("Progress area is unsupported") unless items.all? { |entry| area_present?(entry.area_id) }
      end

      private def reject_direct_catalogue!(_areas : Array(Area)) : Nil
        raise ArgumentError.new("update_areas must change the catalogue")
      end

      private def reject_direct_maps!(_maps : Array(MapInfo)) : Nil
        raise ArgumentError.new("update_catalogue must change the maps")
      end

      private def after_restore_state : Nil
        restored = @selected_areas.select { |id| area_present?(id) }.uniq!
        if restored != @selected_areas
          @selected_areas = restored
          increment_version
        end
      end
    end
  end
end
