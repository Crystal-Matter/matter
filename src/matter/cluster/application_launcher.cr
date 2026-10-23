require "./cluster"

module Matter
  module Cluster
    # Matter 1.6 Application Launcher server (0x050C). The host implements
    # application lifecycle and updates CurrentApp when foreground focus changes.
    class ApplicationLauncher < Base
      cluster 0x050C, revision: 2

      feature :application_platform, bit: 0

      enum Status : UInt8
        Success             = 0
        AppNotAvailable     = 1
        SystemBusy          = 2
        PendingUserApproval = 3
        Downloading         = 4
        Installing          = 5
      end

      struct Application
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter catalog_vendor_id : UInt16
        @[TLV::Field(tag: 1)]
        getter application_id : String

        def initialize(@catalog_vendor_id : UInt16, @application_id : String)
        end
      end

      struct ApplicationEP
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter application : Application
        @[TLV::Field(tag: 1, optional: true)]
        getter endpoint : UInt16?

        def initialize(@application : Application, @endpoint : UInt16? = nil)
        end
      end

      struct LaunchAppRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter application : Application?
        @[TLV::Field(tag: 1, optional: true)]
        getter data : Bytes?

        def initialize(@application : Application? = nil, @data : Bytes? = nil)
        end
      end

      struct StopAppRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter application : Application?

        def initialize(@application : Application? = nil)
        end
      end

      struct HideAppRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0, optional: true)]
        getter application : Application?

        def initialize(@application : Application? = nil)
        end
      end

      struct LauncherResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter status : Status
        @[TLV::Field(tag: 1, optional: true)]
        getter data : Bytes?

        def initialize(@status : Status, @data : Bytes? = nil)
        end
      end

      attribute 0x0000, :catalog_list, Array(UInt16),
        default: [] of UInt16, persist: true, requires: :application_platform,
        copy_on_assign: true, validate: :validate_catalog_list!
      attribute 0x0001, :current_app, ApplicationEP,
        nullable: true, optional: true, present_if: :current_app_supported?

      command 0x00, :launch_app, request: LaunchAppRequest,
        response: LauncherResponse, response_id: 0x03, access: :operate
      command 0x01, :stop_app, request: StopAppRequest,
        response: LauncherResponse, response_id: 0x03, access: :operate
      command 0x02, :hide_app, request: HideAppRequest,
        response: LauncherResponse, response_id: 0x03, access: :operate

      @launch_app_callback : Proc(LaunchAppRequest, LauncherResponse)?
      @stop_app_callback : Proc(StopAppRequest, LauncherResponse)?
      @hide_app_callback : Proc(HideAppRequest, LauncherResponse)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     catalog_list : Array(UInt16) = [] of UInt16,
                     @current_app_supported : Bool = true,
                     @current_app : ApplicationEP? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_catalog_list!(catalog_list)
        @catalog_list = catalog_list.dup
      end

      def catalog_list : Array(UInt16)
        @catalog_list.dup
      end

      def current_app_supported? : Bool
        @current_app_supported
      end

      def on_launch_app(&block : LaunchAppRequest -> LauncherResponse) : Nil
        @launch_app_callback = block
      end

      def on_stop_app(&block : StopAppRequest -> LauncherResponse) : Nil
        @stop_app_callback = block
      end

      def on_hide_app(&block : HideAppRequest -> LauncherResponse) : Nil
        @hide_app_callback = block
      end

      def launch_app(request : LaunchAppRequest) : LauncherResponse | InteractionModel::Status
        if error = application_error(request.application)
          return error
        end
        callback = @launch_app_callback
        return InteractionModel::Status.invalid_in_state unless callback
        callback.call(request)
      end

      def stop_app(request : StopAppRequest) : LauncherResponse | InteractionModel::Status
        if error = application_error(request.application)
          return error
        end
        callback = @stop_app_callback
        return InteractionModel::Status.invalid_in_state unless callback
        callback.call(request)
      end

      def hide_app(request : HideAppRequest) : LauncherResponse | InteractionModel::Status
        if error = application_error(request.application)
          return error
        end
        callback = @hide_app_callback
        return InteractionModel::Status.invalid_in_state unless callback
        callback.call(request)
      end

      private def application_error(application : Application?)
        return InteractionModel::Status.constraint_error if @feature_map.application_platform? != !application.nil?
        if application && !@catalog_list.includes?(application.catalog_vendor_id)
          return LauncherResponse.new(Status::AppNotAvailable)
        end
        nil
      end

      private def validate_catalog_list!(catalogs : Array(UInt16)) : Nil
        unless @feature_map.application_platform? || catalogs.empty?
          raise ArgumentError.new("CatalogList requires ApplicationPlatform")
        end
        unless catalogs.to_set.size == catalogs.size
          raise ArgumentError.new("CatalogList entries must be unique")
        end
      end
    end
  end
end
