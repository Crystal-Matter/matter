require "log"

require "../protocol/icd/check_in_message"
require "../protocol/message_type"
require "../cluster/icd_management"
require "../node"
require "./client"
require "./icd_peer_store"
require "./im_client"
require "./state"

module Matter
  module Controller
    # Authenticates unsolicited ICD Check-In messages before delivering a
    # fabric-bound peer identity. The UDP sender address is only a return hint.
    class IcdClient
      Log = ::Log.for("matter.controller.icd_client")

      PROTOCOL_SECURE_CHANNEL      = Client::PROTOCOL_SECURE_CHANNEL
      ACTIVE_MODE_THRESHOLD_LENGTH =               2
      COUNTER_REFRESH_OFFSET       = 0x8000_0000_u32
      ICD_ENDPOINT                 = Node::ROOT_ENDPOINT_ID

      record CheckIn, fabric_id : UInt64, root_public_key : Bytes,
        controller_node_id : UInt64, device_node_id : UInt64,
        counter : UInt32, active_mode_threshold : UInt16,
        peer : Socket::IPAddress, needs_key_refresh : Bool

      property on_check_in : Proc(CheckIn, Nil)?

      @observer_id : Int32
      @im : ImClient

      def initialize(@client : Client, @store : IcdPeerStore, im : ImClient? = nil)
        @im = im || ImClient.new(@client)
        @observer_id = @client.transport.add_message_observer do |message, peer|
          if message.packet_header.session_id == Client::UNSECURED_SESSION_ID &&
             message.payload_header.protocol_id == PROTOCOL_SECURE_CHANNEL &&
             message.payload_header.message_type == Protocol::SecureChannelMessageType::IcdCheckIn.value &&
             message.payload_header.initiator_message?
            accept_check_in(message.payload, peer)
            true
          else
            false
          end
        end
      end

      def close : Nil
        @client.transport.remove_message_observer(@observer_id)
      end

      # Register a permanent client over a CASE session. Persist the candidate
      # before sending because a lost InvokeResponse may mean the ICD accepted
      # the new key and can already send a Check-In with it.
      def register_client(fabric : FabricInfo, device_node_id : UInt64,
                          session : Session::SecureContext,
                          peer : Socket::IPAddress,
                          monitored_subject : UInt64 = fabric.controller_node_id,
                          key : Bytes = Random::Secure.random_bytes(IcdPeerStore::KEY_LENGTH),
                          endpoint_id : UInt16 = ICD_ENDPOINT) : IcdPeerStore::Record
        validate_case_peer!(fabric, device_node_id, session)
        prior = @store.find_peer(fabric.fabric_id, fabric.root_public_key,
          fabric.controller_node_id, device_node_id)
        if prior.try(&.pending_key)
          raise Matter::ConfigurationError.new("ICD key refresh is already pending confirmation")
        end
        staged = if previous = prior
                   IcdPeerStore::Record.new(fabric.fabric_id, fabric.root_public_key,
                     fabric.controller_node_id, device_node_id, previous.key,
                     previous.counter_start, previous.last_counter, key, nil)
                 else
                   IcdPeerStore::Record.new(fabric.fabric_id, fabric.root_public_key,
                     fabric.controller_node_id, device_node_id, key)
                 end
        @store.save(staged)
        request = Cluster::IcdManagement::RegisterClientRequest.new(
          fabric.controller_node_id, monitored_subject, key,
          prior.try(&.key), Cluster::IcdManagement::ClientType::Permanent)
        response = @im.invoke(session, peer, endpoint_id,
          Cluster::IcdManagement::CLUSTER_ID,
          Cluster::IcdManagement::CMD_REGISTER_CLIENT, request.to_slice)
        counter = begin
          register_response_counter!(response, endpoint_id)
        rescue ex : Matter::ClusterError
          if previous = prior
            @store.save(previous)
          else
            @store.delete_peer(fabric.fabric_id, fabric.root_public_key,
              fabric.controller_node_id, device_node_id)
          end
          raise ex
        end
        latest = @store.find_peer(fabric.fabric_id, fabric.root_public_key,
          fabric.controller_node_id, device_node_id).as(IcdPeerStore::Record)
        # A Check-In can confirm the key while the InvokeResponse is in
        # flight. Preserve the accepted counter and only move its baseline
        # back to the reported start when it precedes that Check-In.
        updated = if latest.key == key && latest.pending_key.nil?
                    start = confirmed_start(counter, latest)
                    IcdPeerStore::Record.new(latest.fabric_id,
                      latest.root_public_key, latest.controller_node_id,
                      latest.device_node_id, latest.key, start,
                      latest.last_counter)
                  elsif latest.pending_key == key
                    IcdPeerStore::Record.new(latest.fabric_id,
                      latest.root_public_key, latest.controller_node_id,
                      latest.device_node_id, latest.key,
                      latest.counter_start, latest.last_counter,
                      latest.pending_key, counter)
                  else
                    raise Matter::ProtocolError.new("ICD registration key changed during InvokeResponse")
                  end
        @store.save(updated)
        updated
      end

      def unregister_client(fabric : FabricInfo, device_node_id : UInt64,
                            session : Session::SecureContext,
                            peer : Socket::IPAddress,
                            endpoint_id : UInt16 = ICD_ENDPOINT) : Nil
        validate_case_peer!(fabric, device_node_id, session)
        record = @store.find_peer(fabric.fabric_id, fabric.root_public_key,
          fabric.controller_node_id, device_node_id)
        request = Cluster::IcdManagement::UnregisterClientRequest.new(
          fabric.controller_node_id, record.try(&.key))
        response = @im.invoke(session, peer, endpoint_id,
          Cluster::IcdManagement::CLUSTER_ID,
          Cluster::IcdManagement::CMD_UNREGISTER_CLIENT, request.to_slice)
        check_status_response!(response, endpoint_id,
          Cluster::IcdManagement::CMD_UNREGISTER_CLIENT)
        @store.delete_peer(fabric.fabric_id, fabric.root_public_key,
          fabric.controller_node_id, device_node_id)
      end

      # Returns false when no registered key authenticated the packet. A
      # replay is claimed but never delivered to the application.
      def accept_check_in(payload : Bytes, peer : Socket::IPAddress) : Bool
        @store.records.each do |record|
          candidate = decode_with(record.key, payload)
          pending = false
          unless candidate
            if key = record.pending_key
              candidate = decode_with(key, payload)
              pending = !candidate.nil?
            end
          end
          next unless candidate

          if candidate.application_data.size < ACTIVE_MODE_THRESHOLD_LENGTH
            Log.warn { "Discarding ICD Check-In without an ActiveModeThreshold" }
            return true
          end

          counter = candidate.counter
          if pending
            if last = record.last_counter
              delta = counter &- last
              return true if delta == 0_u32 || delta >= COUNTER_REFRESH_OFFSET
            end
            if start = record.pending_counter_start
              delta = counter &- start
              return true if delta == 0_u32 || delta >= COUNTER_REFRESH_OFFSET
            end
          elsif last = record.last_counter
            start = record.counter_start || last
            return true if (counter &- start) <= (last &- start)
          elsif start = record.counter_start
            return true if (counter &- start) == 0_u32
          end

          key = pending ? record.pending_key.as(Bytes) : record.key
          updated = IcdPeerStore::Record.new(record.fabric_id,
            record.root_public_key, record.controller_node_id,
            record.device_node_id, key,
            pending ? (record.pending_counter_start || record.last_counter || counter) : (record.counter_start || record.last_counter || counter),
            counter, pending ? nil : record.pending_key,
            pending ? nil : record.pending_counter_start)
          @store.save(updated)
          threshold = IO::ByteFormat::LittleEndian.decode(UInt16,
            candidate.application_data[0, ACTIVE_MODE_THRESHOLD_LENGTH])
          start = updated.counter_start.as(UInt32)
          refresh = (counter &- start) >= COUNTER_REFRESH_OFFSET
          if handler = @on_check_in
            begin
              handler.call(CheckIn.new(record.fabric_id,
                record.root_public_key, record.controller_node_id,
                record.device_node_id, counter, threshold, peer, refresh))
            rescue ex : Exception
              Log.warn(exception: ex) { "ICD Check-In handler failed after persisting counter" }
            end
          end
          return true
        end
        false
      end

      private def decode_with(key : Bytes, payload : Bytes) : Protocol::Icd::CheckInMessage::Decoded?
        Protocol::Icd::CheckInMessage.decode(key, payload)
      rescue Matter::CodecError
        nil
      end

      private def confirmed_start(response_start : UInt32,
                                  latest : IcdPeerStore::Record) : UInt32
        if last = latest.last_counter
          delta = last &- response_start
          return latest.counter_start || last if delta >= COUNTER_REFRESH_OFFSET
        end
        response_start
      end

      private def validate_case_peer!(fabric : FabricInfo, device_node_id : UInt64,
                                      session : Session::SecureContext) : Nil
        unless session.case_session? && session.fabric_index &&
               session.local_node_id.try(&.id) == fabric.controller_node_id &&
               session.peer_node_id.try(&.id) == device_node_id
          raise Matter::SessionError.new("ICD registration requires CASE with the requested fabric and peer")
        end
      end

      private def register_response_counter!(response : InteractionModel::InvokeResponseMessage,
                                             endpoint_id : UInt16) : UInt32
        command_id = Cluster::IcdManagement::CMD_REGISTER_CLIENT_RESPONSE
        response.invoke_responses.each do |item|
          if data = item.command_data
            if data.command_path.endpoint == endpoint_id &&
               data.command_path.cluster == Cluster::IcdManagement::CLUSTER_ID &&
               data.command_path.command == command_id
              fields = data.command_fields || raise Matter::ProtocolError.new("ICD RegisterClient response omitted fields")
              return Cluster::IcdManagement::RegisterClientResponse.from_tlv(fields).icd_counter
            end
          elsif status = item.command_status
            unless status.command_path.endpoint == endpoint_id &&
                   status.command_path.cluster == Cluster::IcdManagement::CLUSTER_ID &&
                   status.command_path.command == Cluster::IcdManagement::CMD_REGISTER_CLIENT
              raise Matter::ProtocolError.new("ICD RegisterClient returned a status for another command")
            end
            if status.status.status == InteractionModel::StatusCode::Success.value
              raise Matter::ProtocolError.new("ICD RegisterClient returned a status without its response")
            end
            raise Matter::ClusterError.from_wire("ICD RegisterClient failed",
              status.status.status, status.status.cluster_status)
          end
        end
        raise Matter::ProtocolError.new("ICD RegisterClient response omitted expected command")
      end

      private def check_status_response!(response : InteractionModel::InvokeResponseMessage,
                                         endpoint_id : UInt16, command_id : UInt32) : Nil
        response.invoke_responses.each do |item|
          next unless status = item.command_status
          next unless status.command_path.endpoint == endpoint_id &&
                      status.command_path.cluster == Cluster::IcdManagement::CLUSTER_ID &&
                      status.command_path.command == command_id
          if status.status.status != InteractionModel::StatusCode::Success.value
            raise Matter::ClusterError.from_wire("ICD UnregisterClient failed",
              status.status.status, status.status.cluster_status)
          end
          return
        end
        raise Matter::ProtocolError.new("ICD UnregisterClient response omitted status")
      end
    end
  end
end
