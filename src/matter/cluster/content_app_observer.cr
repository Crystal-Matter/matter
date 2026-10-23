require "./cluster"
require "tlv"

module Matter
  module Cluster
    # Matter 1.6 Content App Observer server (0x0510, revision 1). A Casting
    # Video Client installs a host handler to interpret vendor-defined data.
    class ContentAppObserver < Base
      cluster 0x0510, revision: 1

      MAX_DATA_BYTES          = 500
      MAX_ENCODING_HINT_BYTES = 100

      enum Status : UInt8
        Success        = 0
        UnexpectedData = 1
      end

      struct ContentAppMessageRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter data : String

        @[TLV::Field(tag: 1, optional: true)]
        getter encoding_hint : String?

        def initialize(@data : String, @encoding_hint : String? = nil)
        end
      end

      struct ContentAppMessageResponse
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter status : Status

        @[TLV::Field(tag: 1, optional: true)]
        getter data : String?

        @[TLV::Field(tag: 2, optional: true)]
        getter encoding_hint : String?

        def initialize(@status : Status, @data : String? = nil, @encoding_hint : String? = nil)
        end
      end

      command 0x00, :content_app_message, request: ContentAppMessageRequest,
        response: ContentAppMessageResponse, response_id: 0x01, access: :operate

      @on_message : Proc(ContentAppMessageRequest, UInt8, UInt64, ContentAppMessageResponse)?

      def on_content_app_message(&block : ContentAppMessageRequest, UInt8, UInt64 -> ContentAppMessageResponse) : Nil
        @on_message = block
      end

      def content_app_message(request : ContentAppMessageRequest) : ContentAppMessageResponse | InteractionModel::Status
        return InteractionModel::Status.unsupported_access unless request_is_case_session?
        fabric = request_fabric_index
        node = request_peer_node_id
        return InteractionModel::Status.unsupported_access unless fabric && node
        return InteractionModel::Status.constraint_error unless valid_strings?(request.data, request.encoding_hint)
        handler = @on_message
        return InteractionModel::Status.invalid_in_state unless handler

        response = handler.call(request, fabric, node)
        return InteractionModel::Status.failure unless valid_strings?(response.data, response.encoding_hint)
        response
      end

      private def valid_strings?(data : String?, encoding_hint : String?) : Bool
        (!data || data.bytesize <= MAX_DATA_BYTES) &&
          (!encoding_hint || encoding_hint.bytesize <= MAX_ENCODING_HINT_BYTES)
      end
    end
  end
end
