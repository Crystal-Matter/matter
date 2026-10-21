require "../cluster/ota_provider"
require "../cluster/ota_requestor"
require "../protocol/ota_image"
require "./im_client"
require "./bdx_client"

module Matter
  module Controller
    # Query an OTA Provider over CASE and stage a validated image via BDX.
    # The application owns the seekable, initially empty sink and decides when
    # to install the staged image. The client never buffers the image itself.
    class OtaRequestorClient(I, B)
      alias Provider = Cluster::OtaProvider
      alias Requestor = Cluster::OtaRequestor

      record StagedUpdate,
        header : Protocol::OtaImage::Header,
        update_token : Bytes,
        image_uri : String,
        bytes_downloaded : UInt64

      def initialize(@im : I, @bdx : B, @requestor : Requestor)
        @next_query_deadlines = {} of Tuple(UInt8, UInt64) => Time::Instant
      end

      # A provider's DelayedActionTime is local to its node and fabric. The
      # monotonic deadline need not survive a restart (Core §11.20.6.5.2).
      def next_query_at(session : Session::SecureContext) : Time::Instant?
        fabric = session.fabric_index
        node = session.peer_node_id.try(&.id)
        @next_query_deadlines[{fabric, node}]? if fabric && node
      end

      # Use the DefaultOTAProviders entry scoped to this CASE fabric. An
      # announcement can still be queried explicitly with query_and_download.
      def query_default_and_download(session : Session::SecureContext,
                                     peer : Socket::IPAddress,
                                     vendor_id : UInt16, product_id : UInt16,
                                     current_version : UInt32, sink : IO,
                                     max_image_bytes : UInt64 = Protocol::OtaImage::DEFAULT_MAX_TOTAL) : StagedUpdate?
        fabric_index = session.fabric_index
        provider_node_id = session.peer_node_id.try(&.id)
        unless session.case_session? && fabric_index && provider_node_id
          raise Matter::SessionError.new("OTA default provider query requires a CASE fabric")
        end
        provider = @requestor.default_ota_providers(fabric_index).first?
        return unless provider
        unless provider.provider_node_id == provider_node_id
          raise Matter::SessionError.new("CASE peer does not match the default OTA provider")
        end
        query_and_download(session, peer, provider.endpoint,
          vendor_id, product_id, current_version, sink,
          max_image_bytes: max_image_bytes)
      end

      def query_and_download(session : Session::SecureContext,
                             peer : Socket::IPAddress, provider_endpoint : UInt16,
                             vendor_id : UInt16, product_id : UInt16,
                             current_version : UInt32, sink : IO,
                             max_image_bytes : UInt64 = Protocol::OtaImage::DEFAULT_MAX_TOTAL) : StagedUpdate?
        provider_node_id = session.peer_node_id.try(&.id)
        fabric_index = session.fabric_index
        unless session.case_session? && fabric_index && provider_node_id
          raise Matter::SessionError.new("OTA QueryImage requires an authenticated CASE provider")
        end
        if max_image_bytes < Protocol::OtaImage::PREFIX_SIZE
          raise Matter::ConfigurationError.new("OTA image size limit is too small")
        end
        provider_key = {fabric_index, provider_node_id}
        if deadline = @next_query_deadlines[provider_key]?
          if Time.instant < deadline
            @requestor.transition_to(Requestor::UpdateState::DelayedOnQuery,
              Requestor::ChangeReason::DelayByProvider)
            return
          end
          @next_query_deadlines.delete(provider_key)
        end

        @requestor.transition_to(Requestor::UpdateState::Querying, Requestor::ChangeReason::Unknown)
        request = Provider::QueryImageRequest.new(vendor_id, product_id,
          current_version, [Provider::DownloadProtocol::BdxSynchronous])
        response = @im.invoke(session, peer, provider_endpoint, Provider::CLUSTER_ID,
          Provider::CMD_QUERY_IMAGE, request.to_slice)
        offer = response_fields(response, provider_endpoint, Provider::CMD_QUERY_IMAGE_RESPONSE)
        if offer.status.busy? && offer.delayed_action_time.nil?
          raise Matter::ProtocolError.new("OTA busy response omitted delay")
        end
        if (delay = offer.delayed_action_time) && delay > 0
          @next_query_deadlines[provider_key] = Time.instant + delay.to_i64.seconds
          @requestor.transition_to(Requestor::UpdateState::DelayedOnQuery,
            Requestor::ChangeReason::DelayByProvider)
          return
        end
        case offer.status
        when Provider::QueryStatus::NotAvailable
          @requestor.transition_to(Requestor::UpdateState::Idle, Requestor::ChangeReason::Success)
          return
        when Provider::QueryStatus::Busy
          @requestor.transition_to(Requestor::UpdateState::DelayedOnQuery,
            Requestor::ChangeReason::DelayByProvider)
          return
        when Provider::QueryStatus::DownloadProtocolNotSupported
          @requestor.transition_to(Requestor::UpdateState::Idle, Requestor::ChangeReason::Failure)
          return
        when Provider::QueryStatus::UpdateAvailable
          # Continue below after validating every field in the offer.
        end

        version = offer.software_version || raise Matter::ProtocolError.new("OTA offer omitted software version")
        token = offer.update_token || raise Matter::ProtocolError.new("OTA offer omitted update token")
        uri = offer.image_uri || raise Matter::ProtocolError.new("OTA offer omitted image URI")
        version_string = offer.software_version_string || raise Matter::ProtocolError.new("OTA offer omitted version string")
        unless version > current_version &&
               token.size.in?(Provider::UPDATE_TOKEN_MIN_LENGTH..Provider::UPDATE_TOKEN_MAX_LENGTH) &&
               version_string.bytesize.in?(1..Provider::VERSION_STRING_MAX_SIZE) &&
               uri.bytesize <= Provider::IMAGE_URI_MAX_LENGTH &&
               uri.matches?(Provider::BDX_IMAGE_URI_PATTERN)
          raise Matter::ProtocolError.new("OTA provider returned an invalid image offer")
        end

        # Core §11.20.6.5.2 reserves another BDX authority for future use.
        # The path is sent as received, including any percent escapes.
        uri_node = uri.byte_slice(6, 16).to_u64(16)
        unless uri_node == provider_node_id
          @requestor.transition_to(Requestor::UpdateState::Idle, Requestor::ChangeReason::Failure)
          raise Matter::ProtocolError.new("OTA BDX authority differs from the CASE provider")
        end
        designator = uri.byte_slice(23, uri.bytesize - 23).to_slice

        @requestor.transition_to(Requestor::UpdateState::Downloading,
          Requestor::ChangeReason::Success, version)
        bytes_downloaded = 0_u64
        begin
          bytes_downloaded = @bdx.download(session, peer, designator, sink,
            max_bytes: max_image_bytes)
          sink.seek(0)
          header = Protocol::OtaImage.validate(sink, vendor_id, product_id,
            current_version, version, max_image_bytes)
          unless header.software_version_string == version_string
            raise Protocol::OtaImage::InvalidImage.new("OTA image version string differs from offer")
          end
          sink.seek(0)
          StagedUpdate.new(header, token.dup, uri, bytes_downloaded)
        rescue ex : Matter::Error | IO::Error
          @requestor.emit_download_error(version, bytes_downloaded)
          @requestor.transition_to(Requestor::UpdateState::Idle, Requestor::ChangeReason::Failure)
          raise ex
        end
      rescue ex : Matter::Error | IO::Error
        @requestor.transition_to(Requestor::UpdateState::Idle, Requestor::ChangeReason::Failure)
        raise ex
      end

      # Ask the provider for permission to install a previously validated
      # image. The application must wait delayed_action_time seconds before
      # acting on Proceed, and is responsible for the actual installation.
      def request_apply(session : Session::SecureContext, peer : Socket::IPAddress,
                        provider_endpoint : UInt16,
                        staged : StagedUpdate) : Provider::ApplyUpdateResponse
        provider_node_id = session.peer_node_id.try(&.id)
        unless session.case_session? && session.fabric_index && provider_node_id
          raise Matter::SessionError.new("OTA ApplyUpdateRequest requires an authenticated CASE provider")
        end
        uri = staged.image_uri
        unless uri.matches?(Provider::BDX_IMAGE_URI_PATTERN) &&
               uri.byte_slice(6, 16).to_u64(16) == provider_node_id &&
               staged.update_token.size.in?(Provider::UPDATE_TOKEN_MIN_LENGTH..Provider::UPDATE_TOKEN_MAX_LENGTH)
          raise Matter::ProtocolError.new("OTA staged update does not match the CASE provider")
        end

        request = Provider::ApplyUpdateRequest.new(staged.update_token, staged.header.software_version)
        response = @im.invoke(session, peer, provider_endpoint, Provider::CLUSTER_ID,
          Provider::CMD_APPLY_UPDATE_REQUEST, request.to_slice)
        fields = command_response_fields(response, provider_endpoint,
          Provider::CMD_APPLY_UPDATE_REQUEST_RESPONSE)
        approval = begin
          Provider::ApplyUpdateResponse.from_tlv(fields)
        rescue ex : TLV::DeserializationError
          raise Matter::ProtocolError.new("OTA provider returned malformed ApplyUpdateResponse", cause: ex)
        end
        case approval.action
        when Provider::ApplyAction::Proceed
          state = approval.delayed_action_time > 0 ? Requestor::UpdateState::DelayedOnApply : Requestor::UpdateState::Applying
          reason = approval.delayed_action_time > 0 ? Requestor::ChangeReason::DelayByProvider : Requestor::ChangeReason::Success
          @requestor.transition_to(state, reason, staged.header.software_version)
        when Provider::ApplyAction::AwaitNextAction
          @requestor.transition_to(Requestor::UpdateState::DelayedOnApply,
            Requestor::ChangeReason::DelayByProvider, staged.header.software_version)
        when Provider::ApplyAction::Discontinue
          @requestor.transition_to(Requestor::UpdateState::Idle, Requestor::ChangeReason::Failure)
        end
        approval
      rescue ex : Matter::Error
        @requestor.transition_to(Requestor::UpdateState::Idle, Requestor::ChangeReason::Failure)
        raise ex
      end

      # Call only after the new software is actually running and Basic
      # Information reports software_version. The application must persist the
      # token across any reboot before calling this method.
      def notify_applied(session : Session::SecureContext, peer : Socket::IPAddress,
                         provider_endpoint : UInt16, update_token : Bytes,
                         software_version : UInt32, product_id : UInt16) : Nil
        unless session.case_session? && session.fabric_index && session.peer_node_id &&
               update_token.size.in?(Provider::UPDATE_TOKEN_MIN_LENGTH..Provider::UPDATE_TOKEN_MAX_LENGTH)
          raise Matter::SessionError.new("OTA NotifyUpdateApplied requires a CASE provider and valid token")
        end
        request = Provider::NotifyUpdateAppliedRequest.new(update_token, software_version)
        response = @im.invoke(session, peer, provider_endpoint, Provider::CLUSTER_ID,
          Provider::CMD_NOTIFY_UPDATE_APPLIED, request.to_slice)
        status = response.invoke_responses.find(&.command_status).try(&.command_status)
        unless status && status.command_path.endpoint == provider_endpoint &&
               status.command_path.cluster == Provider::CLUSTER_ID &&
               status.command_path.command == Provider::CMD_NOTIFY_UPDATE_APPLIED
          raise Matter::ProtocolError.new("OTA provider omitted NotifyUpdateApplied status")
        end
        unless status.status.status == InteractionModel::StatusCode::Success.value
          raise Matter::ClusterError.from_wire("OTA NotifyUpdateApplied failed",
            status.status.status, status.status.cluster_status)
        end
        @requestor.emit_version_applied(software_version, product_id)
        @requestor.transition_to(Requestor::UpdateState::Idle, Requestor::ChangeReason::Success)
      end

      private def response_fields(response : InteractionModel::InvokeResponseMessage,
                                  endpoint_id : UInt16,
                                  command_id : UInt32) : Provider::QueryImageResponse
        fields = command_response_fields(response, endpoint_id, command_id)
        begin
          Provider::QueryImageResponse.from_tlv(fields)
        rescue ex : TLV::DeserializationError
          raise Matter::ProtocolError.new("OTA provider returned malformed QueryImageResponse", cause: ex)
        end
      end

      private def command_response_fields(response : InteractionModel::InvokeResponseMessage,
                                          endpoint_id : UInt16,
                                          command_id : UInt32) : TLV::Any
        response.invoke_responses.each do |item|
          if data = item.command_data
            unless data.command_path.endpoint == endpoint_id &&
                   data.command_path.cluster == Provider::CLUSTER_ID &&
                   data.command_path.command == command_id
              raise Matter::ProtocolError.new("OTA provider returned an unexpected command")
            end
            return data.command_fields || raise Matter::ProtocolError.new("OTA provider omitted response fields")
          end
          if status = item.command_status
            raise Matter::ClusterError.from_wire("OTA command failed",
              status.status.status, status.status.cluster_status)
          end
        end
        raise Matter::ProtocolError.new("OTA provider omitted command response")
      end
    end
  end
end
