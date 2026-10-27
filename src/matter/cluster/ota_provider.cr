require "./cluster"

module Matter
  module Cluster
    # OTA Software Update Provider Cluster (0x0029), Matter 1.6 §11.20.6.
    # The application chooses images and owns the update token lifecycle.
    # Commands are accepted only from a CASE peer on a fabric.
    class OtaProvider < Base
      cluster 0x0029, revision: 1, name: "OtaSoftwareUpdateProvider"

      enum QueryStatus : UInt8
        UpdateAvailable              = 0
        Busy                         = 1
        NotAvailable                 = 2
        DownloadProtocolNotSupported = 3
      end

      enum ApplyAction : UInt8
        Proceed         = 0
        AwaitNextAction = 1
        Discontinue     = 2
      end

      enum DownloadProtocol : UInt8
        BdxSynchronous  = 0
        BdxAsynchronous = 1
        Https           = 2
        VendorSpecific  = 3
      end

      UPDATE_TOKEN_MIN_LENGTH =   8
      UPDATE_TOKEN_MAX_LENGTH =  32
      METADATA_MAX_LENGTH     = 512
      IMAGE_URI_MAX_LENGTH    = 256
      VERSION_STRING_MAX_SIZE =  64
      MAX_PROTOCOLS_SUPPORTED =   8
      BDX_IMAGE_URI_PATTERN   = /\Abdx:\/\/[0-9A-F]{16}\/(?:[A-Za-z0-9._~!$&'()*+,;=:@\/-]|%[0-9A-Fa-f]{2})+\z/
      HTTPS_IMAGE_URI_PATTERN = /\Ahttps:\/\/[^\s\/?#@]+(?:\/[^\s#]*)?(?:\?[^\s#]*)?(?:\#[^\s]*)?\z/

      record RequestContext, fabric_index : UInt8, peer_node_id : UInt64

      struct QueryImageRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property vendor_id : UInt16

        @[TLV::Field(tag: 1)]
        property product_id : UInt16

        @[TLV::Field(tag: 2)]
        property software_version : UInt32

        @[TLV::Field(tag: 3)]
        property protocols_supported : Array(DownloadProtocol)

        @[TLV::Field(tag: 4, optional: true)]
        property hardware_version : UInt16?

        @[TLV::Field(tag: 5, optional: true)]
        property location : String?

        @[TLV::Field(tag: 6, optional: true)]
        property requestor_can_consent : Bool?

        @[TLV::Field(tag: 7, optional: true)]
        property metadata_for_provider : Bytes?

        def initialize(@vendor_id : UInt16, @product_id : UInt16,
                       @software_version : UInt32,
                       @protocols_supported : Array(DownloadProtocol),
                       @hardware_version : UInt16? = nil,
                       @location : String? = nil,
                       @requestor_can_consent : Bool? = nil,
                       @metadata_for_provider : Bytes? = nil)
        end
      end

      struct QueryImageResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property status : QueryStatus

        @[TLV::Field(tag: 1, optional: true)]
        property delayed_action_time : UInt32?

        @[TLV::Field(tag: 2, optional: true)]
        property image_uri : String?

        @[TLV::Field(tag: 3, optional: true)]
        property software_version : UInt32?

        @[TLV::Field(tag: 4, optional: true)]
        property software_version_string : String?

        @[TLV::Field(tag: 5, optional: true)]
        property update_token : Bytes?

        @[TLV::Field(tag: 6, optional: true)]
        property user_consent_needed : Bool?

        @[TLV::Field(tag: 7, optional: true)]
        property metadata_for_requestor : Bytes?

        def initialize(@status : QueryStatus,
                       @delayed_action_time : UInt32? = nil,
                       @image_uri : String? = nil,
                       @software_version : UInt32? = nil,
                       @software_version_string : String? = nil,
                       @update_token : Bytes? = nil,
                       @user_consent_needed : Bool? = nil,
                       @metadata_for_requestor : Bytes? = nil)
        end

        def self.available(image_uri : String, software_version : UInt32,
                           software_version_string : String, update_token : Bytes) : self
          new(QueryStatus::UpdateAvailable, image_uri: image_uri,
            software_version: software_version,
            software_version_string: software_version_string,
            update_token: update_token)
        end
      end

      struct ApplyUpdateRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property update_token : Bytes

        @[TLV::Field(tag: 1)]
        property new_version : UInt32

        def initialize(@update_token : Bytes, @new_version : UInt32)
        end
      end

      struct ApplyUpdateResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property action : ApplyAction

        @[TLV::Field(tag: 1)]
        property delayed_action_time : UInt32

        def initialize(@action : ApplyAction, @delayed_action_time : UInt32)
        end
      end

      struct NotifyUpdateAppliedRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        property update_token : Bytes

        @[TLV::Field(tag: 1)]
        property software_version : UInt32

        def initialize(@update_token : Bytes, @software_version : UInt32)
        end
      end

      command 0x00, :query_image, request: QueryImageRequest,
        response: QueryImageResponse, response_id: 0x01
      command 0x02, :apply_update_request, request: ApplyUpdateRequest,
        response: ApplyUpdateResponse, response_id: 0x03
      command 0x04, :notify_update_applied, request: NotifyUpdateAppliedRequest

      property on_query_image : Proc(RequestContext, QueryImageRequest, QueryImageResponse)?
      property on_apply_update : Proc(RequestContext, ApplyUpdateRequest, ApplyUpdateResponse)?
      property on_notify_update_applied : Proc(RequestContext, NotifyUpdateAppliedRequest, Nil)?

      def initialize(endpoint_id : DataType::EndpointNumber = DataType::EndpointNumber::ROOT)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      def query_image(request : QueryImageRequest) : QueryImageResponse | InteractionModel::Status
        context = authenticated_context || return InteractionModel::Status.unsupported_access
        return InteractionModel::Status.constraint_error unless valid_query?(request)
        unless request.protocols_supported.includes?(DownloadProtocol::BdxSynchronous) ||
               request.protocols_supported.includes?(DownloadProtocol::Https)
          return QueryImageResponse.new(QueryStatus::DownloadProtocolNotSupported)
        end

        response = @on_query_image.try(&.call(context, request)) ||
                   QueryImageResponse.new(QueryStatus::NotAvailable)
        return InteractionModel::Status.constraint_error unless valid_response?(response, request)
        response
      end

      def apply_update_request(request : ApplyUpdateRequest) : ApplyUpdateResponse | InteractionModel::Status
        context = authenticated_context || return InteractionModel::Status.unsupported_access
        return InteractionModel::Status.constraint_error unless valid_token?(request.update_token)
        @on_apply_update.try(&.call(context, request)) ||
          ApplyUpdateResponse.new(ApplyAction::Discontinue, 0_u32)
      end

      def notify_update_applied(request : NotifyUpdateAppliedRequest) : InteractionModel::Status
        context = authenticated_context || return InteractionModel::Status.unsupported_access
        return InteractionModel::Status.constraint_error unless valid_token?(request.update_token)
        @on_notify_update_applied.try(&.call(context, request))
        InteractionModel::Status.success
      end

      private def authenticated_context : RequestContext?
        return unless request_is_case_session?
        fabric = request_fabric_index
        node = request_peer_node_id
        RequestContext.new(fabric, node) if fabric && node
      end

      private def valid_query?(request : QueryImageRequest) : Bool
        protocols = request.protocols_supported
        return false if protocols.empty? || protocols.size > MAX_PROTOCOLS_SUPPORTED
        return false if (location = request.location) && location.bytesize != 2
        return false if (metadata = request.metadata_for_provider) && metadata.size > METADATA_MAX_LENGTH
        true
      end

      private def valid_response?(response : QueryImageResponse,
                                  request : QueryImageRequest) : Bool
        return false if (metadata = response.metadata_for_requestor) && metadata.size > METADATA_MAX_LENGTH
        if response.status.update_available?
          uri = response.image_uri
          version_string = response.software_version_string
          token = response.update_token
          version = response.software_version
          return false unless uri && version_string && token && version
          return false if uri.empty? || uri.bytesize > IMAGE_URI_MAX_LENGTH
          return false if version_string.empty? || version_string.bytesize > VERSION_STRING_MAX_SIZE
          return false unless version > request.software_version && valid_token?(token)
          return valid_image_uri?(uri, request.protocols_supported)
        end
        return false if response.status.busy? && response.delayed_action_time.nil?
        response.image_uri.nil? && response.software_version.nil? &&
          response.software_version_string.nil? && response.update_token.nil?
      end

      private def valid_token?(token : Bytes) : Bool
        token.size >= UPDATE_TOKEN_MIN_LENGTH && token.size <= UPDATE_TOKEN_MAX_LENGTH
      end

      private def valid_image_uri?(uri : String, protocols : Array(DownloadProtocol)) : Bool
        if uri.starts_with?("bdx:")
          protocols.includes?(DownloadProtocol::BdxSynchronous) &&
            uri.matches?(BDX_IMAGE_URI_PATTERN)
        elsif uri.starts_with?("https:")
          protocols.includes?(DownloadProtocol::Https) &&
            uri.matches?(HTTPS_IMAGE_URI_PATTERN)
        else
          false
        end
      end
    end
  end
end
