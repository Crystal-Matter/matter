require "log"

require "../../cluster/general_commissioning"
require "../../cluster/network_commissioning"
require "../../cluster/operational_credentials"
require "../../crypto/certificate"
require "../../crypto/key"
require "../scanner"
require "../../setup_payload"

require "../certificate_util"
require "../device_attestation_verifier"
require "../client"
require "../im_client"
require "../pairing/case_pairing"
require "../pairing/pase_pairing"
require "../state"
require "../state_store"
require "../datastore_node_registrar"

module Matter
  module Controller
    module Commissioning
      class Commissioner
        Log                              = ::Log.for("matter.controller.commissioning.commissioner")
        FAIL_SAFE_RECOVERY_GRACE_SECONDS = 2_i64
        FAIL_SAFE_REFRESH_FRACTION       =     2
        REGULATORY_BREADCRUMB            = 1_u64

        record FailSafeWindow,
          primary_expires_at : Time::Instant,
          expires_at_unix : Int64,
          cumulative_expires_at_unix : Int64

        # fabric ID, device Node ID, CSR public key -> issued Matter NOC.
        alias CertificateIssuer = Proc(UInt64, UInt64, Bytes, Bytes)

        # Credentials and administrator metadata sent with AddNOC. Joint
        # commissioning may replace these after authenticating the anchor.
        struct OperationalCredentials
          getter noc : Bytes
          getter icac : Bytes?
          getter ipk : Bytes
          getter case_admin_subject : UInt64
          getter admin_vendor_id : UInt16

          def initialize(@noc, @icac, @ipk, @case_admin_subject, @admin_vendor_id)
          end
        end

        abstract class Hooks
          abstract def prepare_credentials(
            fabric : FabricInfo,
            node_id : UInt64,
            csr_public_key : Bytes,
            im : ImClient,
            pase_session : Session::SecureContext,
            peer : Socket::IPAddress,
          ) : OperationalCredentials

          abstract def before_complete(
            fabric : FabricInfo,
            node_id : UInt64,
            im : ImClient,
            case_session : Session::SecureContext,
            peer : Socket::IPAddress,
          ) : Nil

          def after_complete(
            fabric : FabricInfo,
            node_id : UInt64,
            im : ImClient,
            case_session : Session::SecureContext,
            peer : Socket::IPAddress,
          ) : Nil
          end

          # Called only after the peer acknowledged CommissioningComplete, and
          # before saving the controller node. Hooks may persist this boundary
          # so a failed controller-state write can be recovered after restart.
          def complete_acknowledged(
            fabric : FabricInfo,
            node_id : UInt64,
            peer : Socket::IPAddress,
          ) : Nil
          end

          def record_fail_safe_deadline? : Bool
            false
          end

          def fail_safe_deadline_observed(deadline_unix : Int64, max_seconds : UInt16) : Nil
          end

          def supports_deferred_handoff? : Bool
            false
          end

          def finalize_deferred_handoff(fabric : FabricInfo, node_id : UInt64,
                                        im : ImClient, pase_session : Session::SecureContext,
                                        peer : Socket::IPAddress,
                                        handoff : PendingCommissioningHandoff) : Nil
            raise Matter::ConfigurationError.new("Commissioner hooks do not support deferred handoff")
          end

          def after_deferred_handoff(fabric : FabricInfo, node_id : UInt64,
                                     peer : Socket::IPAddress) : Nil
          end
        end

        # This controller runs one certificate authority per fabric, so the root
        # certificate it issues is always the first one.
        ROOT_CERTIFICATE_ID =      1_u64
        ANCHOR_ICAC_ID      =      3_u64
        ANCHOR_CAT_ID       = 0xFFFE_u32
        # Serial numbers only have to be distinguishable within a fabric
        CERTIFICATE_SERIAL_BYTES = 8

        def initialize(
          @store : StateStore,
          @client : Client = Client.new,
          @timeout : Time::Span = 15.seconds,
          @crypto : Crypto::CryptoBase = Crypto::StandardCrypto.new,
          @certificate_issuer : CertificateIssuer? = nil,
          @hooks : Hooks? = nil,
          @controller_cats : Array(UInt32) = [] of UInt32,
          @fail_safe_expiry_seconds : UInt16 = 60_u16,
          @attestation_verifier : DeviceAttestationVerifier? = nil,
          @datastore_registrar : DatastoreNodeRegistrar? = nil,
          @regulatory_location : Cluster::GeneralCommissioning::RegulatoryLocationType? = nil,
          @regulatory_country_code : String? = nil,
        )
          if @fail_safe_expiry_seconds == 0_u16 ||
             @fail_safe_expiry_seconds > ::Matter::Commissioning::FailsafeService::DEFAULT_MAX_CUMULATIVE_SECONDS
            raise Matter::ConfigurationError.new("Commissioning fail-safe expiry must be between 1 and #{::Matter::Commissioning::FailsafeService::DEFAULT_MAX_CUMULATIVE_SECONDS} seconds")
          end
          if country = @regulatory_country_code
            unless country.size == 2 && country.chars.all?(&.ascii_uppercase?)
              raise Matter::ConfigurationError.new("Regulatory country code must be two uppercase letters")
            end
          end
        end

        def close : Nil
          @client.close
        end

        def pairing_code(
          node_id : UInt64,
          manual_code : String,
          peer : Socket::IPAddress? = nil,
          fabric_id : UInt64? = nil,
          root_public_key : Bytes? = nil,
          controller_node_id : UInt64? = nil,
          new_fabric : Bool = false,
          defer_completion : Bool = false,
          friendly_name : String? = nil,
        ) : PendingCommissioningHandoff?
          if @datastore_registrar && friendly_name.nil?
            raise Matter::ConfigurationError.new("Datastore registration requires a friendly name")
          end
          if defer_completion && @hooks && !@hooks.as(Hooks).supports_deferred_handoff?
            raise Matter::ConfigurationError.new("JCM hooks require an explicit Anchor handoff workflow before deferring CommissioningComplete")
          end
          discriminator, pin_code = SetupPayload.parse_manual_code(manual_code)
          state = @store.load

          if (root_public_key || controller_node_id) && fabric_id.nil?
            raise Matter::ConfigurationError.new("Selecting a fabric by root public key or controller Node ID also requires a fabric ID")
          end
          if new_fabric && fabric_id
            raise Matter::ConfigurationError.new("Cannot select an existing fabric while creating a new one")
          end
          fabric = new_fabric ? nil : (fabric_id ? state.fabric_for(fabric_id, root_public_key, controller_node_id) : state.fabric)
          unless fabric
            fabric = create_fabric(controller_node_id: state.commissioner_node_id)
            state.install_fabric(fabric)
          end
          if fabric.root_private_key.nil? && fabric.intermediate_private_key.nil? && @certificate_issuer.nil? && @hooks.nil?
            raise Matter::ConfigurationError.new("Commissioning on this fabric requires a certificate issuer")
          end
          verifier = @attestation_verifier ||
                     raise Matter::ConfigurationError.new("Device attestation requires an explicitly configured verifier and trust store")
          if @datastore_registrar && state.nodes_for(fabric.fabric_id, fabric.root_public_key,
               fabric.controller_node_id).has_key?(node_id)
            raise Matter::CommissioningError.new("Controller already has a commissioned node with this Node ID")
          end
          @store.save(state)

          peer_addr = peer || discover_commissionable(discriminator)

          Log.info { "Commissioning: discriminator=#{discriminator} node_id=0x#{node_id.to_s(16)} peer=#{peer_addr}" }

          pase = Pairing::PasePairing.new(@crypto)
          pase_session = pase.pair(@client, peer_addr, pin_code, timeout: @timeout)
          @client.register_session(pase_session)

          im = ImClient.new(@client, @timeout)

          arm = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
            expiry_length_seconds: @fail_safe_expiry_seconds,
            breadcrumb: 0_u64,
            timeout_ms: 0_u32
          )
          arm_resp = im.invoke(
            session: pase_session,
            peer: peer_addr,
            endpoint_id: 0_u16,
            cluster_id: Cluster::GeneralCommissioning::CLUSTER_ID,
            command_id: Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE,
            fields: arm.to_slice
          )
          assert_commissioning_response!(arm_resp,
            Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE_RESPONSE, "ArmFailSafe")
          info_report = im.read_attribute(pase_session, peer_addr, 0_u16,
            Cluster::GeneralCommissioning::CLUSTER_ID,
            Cluster::GeneralCommissioning::ATTR_BASIC_COMMISSIONING_INFO)
          info_data = info_report.attribute_reports.try(&.find(&.attribute_data))
            .try(&.attribute_data).try(&.data) ||
                      raise Matter::ProtocolError.new("BasicCommissioningInfo read omitted data")
          info = Cluster::GeneralCommissioning::BasicCommissioningInfo.from_slice(info_data.to_slice)
          if info.max_cumulative_failsafe_seconds == 0_u16
            raise Matter::CommissioningError.new("Device reported no maximum cumulative fail-safe duration")
          end
          now_unix = Time.utc.to_unix
          cumulative_expires_at_unix = now_unix + info.max_cumulative_failsafe_seconds.to_i64
          fail_safe_window = FailSafeWindow.new(Time.instant + @fail_safe_expiry_seconds.seconds,
            {now_unix + @fail_safe_expiry_seconds.to_i64, cumulative_expires_at_unix}.min,
            cumulative_expires_at_unix)

          configure_regulatory_information(im, pase_session, peer_addr)
          fail_safe_window = rearm_fail_safe_if_needed(im, pase_session, peer_addr, fail_safe_window)

          if hooks = @hooks
            if hooks.record_fail_safe_deadline?
              hooks.fail_safe_deadline_observed(cumulative_expires_at_unix + FAIL_SAFE_RECOVERY_GRACE_SECONDS,
                info.max_cumulative_failsafe_seconds)
            end
          end

          vendor_id = read_basic_information(im, pase_session, peer_addr, Cluster::BasicInformation::ATTR_VENDOR_ID).as_u16
          product_id = read_basic_information(im, pase_session, peer_addr, Cluster::BasicInformation::ATTR_PRODUCT_ID).as_u16
          dac = request_certificate(im, pase_session, peer_addr,
            Cluster::OperationalCredentials::Tlv::CertificateChainType::DacCertificate)
          pai = request_certificate(im, pase_session, peer_addr,
            Cluster::OperationalCredentials::Tlv::CertificateChainType::PaiCertificate)
          attestation_nonce = @crypto.random_bytes(DeviceAttestationVerifier::NONCE_SIZE)
          attestation_request = Cluster::OperationalCredentials::Tlv::AttestationRequest.new(attestation_nonce)
          attestation_invocation = im.invoke(session: pase_session, peer: peer_addr,
            endpoint_id: 0_u16, cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
            command_id: Cluster::OperationalCredentials::CMD_ATTESTATION_REQUEST,
            fields: attestation_request.to_slice)
          attestation = Cluster::OperationalCredentials::Tlv::AttestationResponse.from_slice(
            first_command_fields(attestation_invocation, Cluster::OperationalCredentials::CMD_ATTESTATION_REQUEST_RESPONSE))
          challenge = pase_session.attestation_challenge ||
                      raise Matter::AuthenticationError.new("PASE session has no attestation challenge")
          dac_public_key = verifier.verify_attestation(dac, pai, attestation.attestation_elements,
            attestation.attestation_signature, attestation_nonce, challenge, vendor_id, product_id)
          fail_safe_window = rearm_fail_safe_if_needed(im, pase_session, peer_addr, fail_safe_window)

          csr_nonce = @crypto.random_bytes(32)
          csr_req = Cluster::OperationalCredentials::Tlv::CsrRequest.new(
            csr_nonce: csr_nonce.to_slice,
            is_for_update_noc: nil
          )
          csr_resp_msg = im.invoke(
            session: pase_session,
            peer: peer_addr,
            endpoint_id: 0_u16,
            cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
            command_id: Cluster::OperationalCredentials::CMD_CSR_REQUEST,
            fields: csr_req.to_slice
          )
          csr_fields = first_command_fields(csr_resp_msg, Cluster::OperationalCredentials::CMD_CSR_REQUEST_RESPONSE)
          csr_resp = Cluster::OperationalCredentials::Tlv::CsrResponse.from_slice(csr_fields)
          device_pub_key = verifier.verify_csr(csr_resp, csr_nonce, challenge, dac_public_key)
          fail_safe_window = rearm_fail_safe_if_needed(im, pase_session, peer_addr, fail_safe_window)

          add_root_req = Cluster::OperationalCredentials::Tlv::AddTrustedRootCertificateRequest.new(
            root_certificate: fabric.root_cert.to_slice
          )
          add_root_resp = im.invoke(
            session: pase_session,
            peer: peer_addr,
            endpoint_id: 0_u16,
            cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
            command_id: Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
            fields: add_root_req.to_slice
          )
          assert_invoke_ok!(add_root_resp, "AddTrustedRootCertificate")
          fail_safe_window = rearm_fail_safe_if_needed(im, pase_session, peer_addr, fail_safe_window)

          credentials = if hooks = @hooks
                          hooks.prepare_credentials(fabric, node_id, device_pub_key, im, pase_session, peer_addr)
                        else
                          OperationalCredentials.new(
                            issue_device_noc(fabric, node_id, device_pub_key),
                            fabric.intermediate_cert,
                            fabric.ipk_value,
                            fabric.controller_node_id,
                            fabric.admin_vendor_id
                          )
                        end
          validate_credentials(credentials, fabric, node_id, device_pub_key)
          fail_safe_window = rearm_fail_safe_if_needed(im, pase_session, peer_addr, fail_safe_window)

          add_noc_req = Cluster::OperationalCredentials::Tlv::AddNocRequest.new(
            noc_value: credentials.noc.to_slice,
            icac_value: credentials.icac,
            ipk_value: credentials.ipk.to_slice,
            case_admin_subject: credentials.case_admin_subject,
            admin_vendor_id: credentials.admin_vendor_id
          )
          add_noc_resp_msg = im.invoke(
            session: pase_session,
            peer: peer_addr,
            endpoint_id: 0_u16,
            cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
            command_id: Cluster::OperationalCredentials::CMD_ADD_NOC,
            fields: add_noc_req.to_slice
          )
          noc_fields = first_command_fields(add_noc_resp_msg, Cluster::OperationalCredentials::CMD_ADD_NOC_RESPONSE)
          noc_resp = Cluster::OperationalCredentials::Tlv::TlvNocResponse.from_slice(noc_fields)
          unless noc_resp.status_code.ok?
            raise Matter::CommissioningError.new("AddNOC failed (status=#{noc_resp.status_code} debug=#{noc_resp.debug_text})")
          end
          fail_safe_window = rearm_fail_safe_if_needed(im, pase_session, peer_addr, fail_safe_window)

          registrar = @datastore_registrar
          registration_attempted = false
          begin
            registration_attempted = !!registrar
            fail_safe_window, handoff = record_pending_commissioning(fabric, node_id,
              friendly_name, peer_addr, im, pase_session, fail_safe_window, defer_completion)

            if defer_completion
              handoff = handoff || raise Matter::ProtocolError.new("Deferred commissioning handoff was not recorded")
              if hooks = @hooks
                registrar.try(&.completing(fabric, node_id))
                hooks.finalize_deferred_handoff(fabric, node_id, im, pase_session, peer_addr, handoff)
                hooks.complete_acknowledged(fabric, node_id, peer_addr)
                registrar.try(&.complete(fabric, node_id))
                state = @store.load
                state.complete_pending_handoff(fabric.fabric_id, fabric.root_public_key,
                  fabric.controller_node_id, node_id, handoff.nonce)
                @store.save(state)
                hooks.after_deferred_handoff(fabric, node_id, peer_addr)
                registrar.try(&.refresh(fabric, node_id))
                return
              end
              registrar.try(&.completing(fabric, node_id))
              return handoff
            end

            case_pairing = Pairing::CasePairing.new(@crypto)
            case_session = case_pairing.pair(@client, peer_addr, fabric, peer_node_id: node_id, timeout: @timeout)
            if hooks = @hooks
              hooks.before_complete(fabric, node_id, im, case_session, peer_addr)
            end
            fail_safe_window = rearm_fail_safe_if_needed(im, case_session, peer_addr, fail_safe_window)
            registrar.try(&.extend_deadline(fabric, node_id, fail_safe_window.expires_at_unix))

            registrar.try(&.completing(fabric, node_id))

            commissioning_complete_resp = im.invoke(
              session: case_session,
              peer: peer_addr,
              endpoint_id: 0_u16,
              cluster_id: Cluster::GeneralCommissioning::CLUSTER_ID,
              command_id: Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE,
              fields: Bytes.empty
            )
            begin
              assert_commissioning_complete!(commissioning_complete_resp)
            rescue ex : Matter::CommissioningError
              # An explicit failed response proves that this invocation did not
              # commission the node. A missing response remains ambiguous.
              begin
                registrar.try(&.abort(fabric, node_id, confirmed_failure: true))
              rescue error
                Log.error(exception: error) { "Datastore RemoveNode cleanup failed for node 0x#{node_id.to_s(16)}" }
              end
              raise ex
            end
            registrar.try(&.complete(fabric, node_id))

            if hooks = @hooks
              hooks.complete_acknowledged(fabric, node_id, peer_addr)
            end

            state = @store.load
            state.record_node(fabric.fabric_id, NodeInfo.new(node_id: node_id, address: peer_addr.address, port: peer_addr.port), fabric.root_public_key, fabric.controller_node_id)
            state.unsecured_message_counter = @client.transport.message_counter.counter
            @store.save(state)
            if hooks = @hooks
              hooks.after_complete(fabric, node_id, im, case_session, peer_addr)
            end
            registrar.try(&.refresh(fabric, node_id))
            nil
          rescue ex
            if registration_attempted
              begin
                registrar.try(&.abort(fabric, node_id))
              rescue error
                Log.error(exception: error) { "Datastore RemoveNode cleanup was deferred for node 0x#{node_id.to_s(16)}" }
              end
            end
            raise ex
          end
        end

        # The JFA must first report that its own CASE CommissioningComplete
        # succeeded. This method records that trusted handoff result; it never
        # sends CommissioningComplete from the controller identity.
        def record_handoff_success(fabric_id : UInt64, root_public_key : Bytes,
                                   controller_node_id : UInt64, node_id : UInt64,
                                   nonce : String) : NodeInfo
          state = @store.load
          node = state.complete_pending_handoff(fabric_id, root_public_key,
            controller_node_id, node_id, nonce)
          @store.save(state)
          if registrar = @datastore_registrar
            fabric = state.fabric_for(fabric_id, root_public_key, controller_node_id)
            registrar.complete(fabric, node_id)
            registrar.refresh(fabric, node_id)
          end
          node
        end

        # Core §5.5 step 8 applies to every WI/TH Network Commissioning
        # instance, including one on a non-root endpoint. Ethernet-only nodes
        # do not need a regulatory command.
        protected def configure_regulatory_information(im : ImClient, session : Session::SecureContext,
                                                       peer : Socket::IPAddress) : Nil
          path = InteractionModel::AttributePath.new(endpoint: nil,
            cluster: Cluster::NetworkCommissioning::CLUSTER_ID,
            attribute: Cluster::Base::GLOBAL_FEATURE_MAP)
          report = im.read(session, peer, attribute_paths: [path])
          wireless = (Cluster::NetworkCommissioning::Feature::WiFiNetworkInterface |
                      Cluster::NetworkCommissioning::Feature::ThreadNetworkInterface).value
          requires_config = (report.attribute_reports || [] of InteractionModel::AttributeReportIB).any? do |entry|
            data = entry.attribute_data
            next false unless data
            concrete = data.path
            next false unless concrete.cluster == Cluster::NetworkCommissioning::CLUSTER_ID &&
                              concrete.attribute == Cluster::Base::GLOBAL_FEATURE_MAP
            (data.data.as_u32 & wireless) != 0
          end
          return unless requires_config

          location = @regulatory_location ||
                     raise Matter::ConfigurationError.new("Wireless commissioning requires regulatory location")
          country = @regulatory_country_code ||
                    raise Matter::ConfigurationError.new("Wireless commissioning requires regulatory country code")
          request = Cluster::GeneralCommissioning::SetRegulatoryConfigRequest.new(
            location, country, REGULATORY_BREADCRUMB)
          response = im.invoke(session, peer, 0_u16, Cluster::GeneralCommissioning::CLUSTER_ID,
            Cluster::GeneralCommissioning::CMD_SET_REGULATORY_CONFIG, request.to_slice)
          assert_commissioning_response!(response,
            Cluster::GeneralCommissioning::CMD_SET_REGULATORY_CONFIG_RESPONSE, "SetRegulatoryConfig")
        end

        # The checkpoint immediately before a deferred handoff uses the
        # refreshed deadline for both durable records. Registering with the
        # Datastore may itself take long enough to require another re-arm.
        protected def record_pending_commissioning(fabric : FabricInfo, node_id : UInt64,
                                                   friendly_name : String?, peer : Socket::IPAddress,
                                                   im : ImClient, session : Session::SecureContext,
                                                   window : FailSafeWindow,
                                                   defer_completion : Bool) : Tuple(FailSafeWindow, PendingCommissioningHandoff?)
          if registrar = @datastore_registrar
            name = friendly_name || raise Matter::ConfigurationError.new("Datastore registration requires a friendly name")
            registrar.add_pending(fabric, node_id, name, window.expires_at_unix, peer)
          end
          window = rearm_fail_safe_if_needed(im, session, peer, window)
          @datastore_registrar.try(&.extend_deadline(fabric, node_id, window.expires_at_unix))
          return {window, nil} unless defer_completion

          handoff = PendingCommissioningHandoff.new(
            fabric.fabric_id, fabric.root_public_key.dup, fabric.controller_node_id,
            node_id, peer.address, peer.port,
            window.expires_at_unix, @crypto.random_bytes(16).hexstring)
          state = @store.load
          state.add_pending_handoff(handoff)
          state.unsecured_message_counter = @client.transport.message_counter.counter
          @store.save(state)
          {window, handoff}
        end

        # Refresh between steps before the primary fail-safe reaches half of
        # its requested lifetime. The device continues enforcing its own
        # cumulative deadline; a refused re-arm is a commissioning failure.
        protected def rearm_fail_safe_if_needed(im : ImClient, session : Session::SecureContext,
                                                peer : Socket::IPAddress,
                                                window : FailSafeWindow) : FailSafeWindow
          return window if window.primary_expires_at - Time.instant >=
                             (@fail_safe_expiry_seconds.to_i / FAIL_SAFE_REFRESH_FRACTION).seconds
          breadcrumb_report = im.read_attribute(session, peer, 0_u16,
            Cluster::GeneralCommissioning::CLUSTER_ID,
            Cluster::GeneralCommissioning::ATTR_BREADCRUMB)
          breadcrumb = breadcrumb_report.attribute_reports.try(&.find(&.attribute_data))
            .try(&.attribute_data).try(&.data).try(&.as_u64) ||
                       raise Matter::ProtocolError.new("ArmFailSafe refresh could not read Breadcrumb")
          request = Cluster::GeneralCommissioning::ArmFailSafeRequest.new(
            expiry_length_seconds: @fail_safe_expiry_seconds,
            breadcrumb: breadcrumb)
          response = im.invoke(session, peer, 0_u16, Cluster::GeneralCommissioning::CLUSTER_ID,
            Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE, request.to_slice)
          assert_commissioning_response!(response,
            Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE_RESPONSE, "ArmFailSafe")
          now_unix = Time.utc.to_unix
          FailSafeWindow.new(Time.instant + @fail_safe_expiry_seconds.seconds,
            {now_unix + @fail_safe_expiry_seconds.to_i64, window.cumulative_expires_at_unix}.min,
            window.cumulative_expires_at_unix)
        end

        private def assert_commissioning_response!(response : InteractionModel::InvokeResponseMessage,
                                                   response_id : UInt32, name : String) : Nil
          assert_invoke_ok!(response, name)
          fields = first_command_fields(response, response_id)
          result = if response_id == Cluster::GeneralCommissioning::CMD_ARM_FAIL_SAFE_RESPONSE
                     Cluster::GeneralCommissioning::ArmFailSafeResponse.from_slice(fields)
                   else
                     Cluster::GeneralCommissioning::SetRegulatoryConfigResponse.from_slice(fields)
                   end
          unless result.error_code.ok?
            raise Matter::CommissioningError.new("#{name} failed (error=#{result.error_code} debug=#{result.debug_text})")
          end
        end

        private def discover_commissionable(discriminator : UInt16) : Socket::IPAddress
          scanner = nil.as(Scanner?)
          scanner = Scanner.new
          scanner.start
          scanner.query_commissioning
          short_only = (discriminator & 0x00ff_u16) == 0_u16
          short_discriminator = SetupPayload.short_discriminator(discriminator)

          deadline = Time.instant + @timeout
          loop do
            dev = scanner.commissioning_devices.find do |device|
              disc = device.discriminator
              next false unless disc
              next true if disc == discriminator
              short_only && SetupPayload.short_discriminator(disc) == short_discriminator
            end
            if dev
              address = dev.addresses.find(&.family.inet?) || dev.addresses.first?
              if addr = address
                return Socket::IPAddress.new(addr.address, dev.port)
              end
            end

            break if Time.instant >= deadline
            sleep 100.milliseconds
          end

          raise Matter::TransportError.new("Failed to discover commissionable node via mDNS (discriminator=#{discriminator})")
        ensure
          scanner.try(&.close)
        end

        private def read_basic_information(im : ImClient, session : Session::SecureContext,
                                           peer : Socket::IPAddress, attribute_id : UInt32) : TLV::Any
          report = im.read_attribute(session, peer, 0_u16, Cluster::BasicInformation::CLUSTER_ID, attribute_id)
          data = report.attribute_reports.try(&.find(&.attribute_data)).try(&.attribute_data).try(&.data)
          data || raise Matter::AuthenticationError.new("BasicInformation attribute #{attribute_id} is missing")
        end

        private def request_certificate(im : ImClient, session : Session::SecureContext,
                                        peer : Socket::IPAddress,
                                        kind : Cluster::OperationalCredentials::Tlv::CertificateChainType) : Bytes
          request = Cluster::OperationalCredentials::Tlv::CertificateChainRequest.new(kind)
          response = im.invoke(session: session, peer: peer, endpoint_id: 0_u16,
            cluster_id: Cluster::OperationalCredentials::CLUSTER_ID,
            command_id: Cluster::OperationalCredentials::CMD_CERTIFICATE_CHAIN_REQUEST,
            fields: request.to_slice)
          Cluster::OperationalCredentials::Tlv::CertificateChainResponse.from_slice(
            first_command_fields(response, Cluster::OperationalCredentials::CMD_CERTIFICATE_CHAIN_REQUEST_RESPONSE)).certificate
        end

        # Create an identity before commissioning when a controller requires a
        # specific CAT, such as the Joint Fabric Anchor Administrator CAT.
        # Install the result with SharedFabric.install before use.
        def create_fabric(controller_node_id : UInt64) : FabricInfo
          fabric_id = loop do
            id = @crypto.random_uint64
            break id unless id == 0_u64
          end

          if controller_node_id == 0_u64
            raise ArgumentError.new("controller_node_id must be non-zero")
          end

          ipk = @crypto.random_bytes(16)

          root_key = Crypto::Key.generate_key_pair
          root_public_key = root_key.public_key
          root_cert = Crypto::MatterCertificate::Builder.root(root_key, ROOT_CERTIFICATE_ID, serial_number, @crypto)

          controller_key = Crypto::Key.generate_key_pair
          anchor_cat = @controller_cats.any? { |cat| cat >> 16 == ANCHOR_CAT_ID }
          intermediate_key = anchor_cat ? Crypto::Key.generate_key_pair : nil
          intermediate_cert = if key = intermediate_key
                                Crypto::MatterCertificate::Builder.intermediate(
                                  key.public_key, fabric_id, ANCHOR_ICAC_ID, root_key,
                                  ROOT_CERTIFICATE_ID, serial_number, @crypto, anchor: true,
                                  issuer_certificate: root_cert
                                )
                              end
          controller_noc = if key = intermediate_key
                             Crypto::MatterCertificate::Builder.node(
                               public_key: controller_key.public_key,
                               fabric_id: fabric_id,
                               node_id: controller_node_id,
                               issuer_key: key,
                               issuer_rcac_id: ROOT_CERTIFICATE_ID,
                               issuer_icac_id: ANCHOR_ICAC_ID,
                               issuer_certificate: intermediate_cert,
                               serial: serial_number,
                               crypto: @crypto,
                               case_authenticated_tags: @controller_cats
                             )
                           else
                             issue_noc(
                               root_key: root_key,
                               root_certificate: root_cert,
                               fabric_id: fabric_id,
                               node_id: controller_node_id,
                               public_key: controller_key.public_key,
                               case_authenticated_tags: @controller_cats
                             )
                           end

          FabricInfo.new(
            fabric_id: fabric_id,
            controller_node_id: controller_node_id,
            ipk_value: ipk,
            root_cert: root_cert,
            root_public_key: root_public_key,
            controller_noc: controller_noc,
            controller_private_key: controller_key.private_key,
            root_private_key: root_key.private_key,
            intermediate_cert: intermediate_cert,
            intermediate_private_key: intermediate_key.try(&.private_key)
          )
        end

        # Issue a node certificate under this fabric's root
        private def issue_noc(root_key : Crypto::Key, fabric_id : UInt64, node_id : UInt64, public_key : Bytes,
                              root_certificate : Bytes,
                              case_authenticated_tags : Array(UInt32) = [] of UInt32) : Bytes
          rcac_id = Crypto::MatterCertificate.from_slice(root_certificate).subject.rcac_id ||
                    raise Matter::CertificateError.new("Root certificate has no RCAC ID")
          Crypto::MatterCertificate::Builder.node(
            public_key: public_key,
            fabric_id: fabric_id,
            node_id: node_id,
            issuer_key: root_key,
            issuer_rcac_id: rcac_id,
            issuer_certificate: root_certificate,
            serial: serial_number,
            crypto: @crypto,
            case_authenticated_tags: case_authenticated_tags
          )
        end

        private def issue_device_noc(fabric : FabricInfo, node_id : UInt64, public_key : Bytes) : Bytes
          noc = if issuer = @certificate_issuer
                  issuer.call(fabric.fabric_id, node_id, public_key)
                elsif icac = fabric.intermediate_cert
                  icac_id = Crypto::MatterCertificate.from_slice(icac).subject.icac_id ||
                            raise Matter::CertificateError.new("Intermediate CA certificate has no ICAC ID")
                  Crypto::MatterCertificate::Builder.node(
                    public_key: public_key,
                    fabric_id: fabric.fabric_id,
                    node_id: node_id,
                    issuer_key: fabric.intermediate_authority_key,
                    issuer_rcac_id: ROOT_CERTIFICATE_ID,
                    issuer_icac_id: icac_id,
                    issuer_certificate: icac,
                    serial: serial_number,
                    crypto: @crypto
                  )
                else
                  issue_noc(fabric.certificate_authority_key, fabric.fabric_id, node_id, public_key,
                    fabric.root_cert)
                end

          Crypto::MatterCertificate::Validation.verify_chain(noc, fabric.intermediate_cert, fabric.root_public_key, fabric.root_cert)
          certificate = Crypto::MatterCertificate.from_slice(noc)
          unless certificate.fabric_id == fabric.fabric_id && certificate.node_id == node_id &&
                 certificate.ec_public_key == public_key
            raise Matter::CertificateError.new("Issued NOC does not match the device CSR and fabric")
          end
          noc
        end

        private def validate_credentials(credentials : OperationalCredentials, fabric : FabricInfo, node_id : UInt64, public_key : Bytes) : Nil
          unless credentials.ipk.size == Fabric::IPK_SIZE && credentials.case_admin_subject != 0_u64
            raise Matter::CertificateError.new("Joint commissioning credentials have invalid IPK or administrator subject")
          end
          Crypto::MatterCertificate::Validation.verify_chain(credentials.noc, credentials.icac, fabric.root_public_key, fabric.root_cert)
          certificate = Crypto::MatterCertificate.from_slice(credentials.noc)
          unless certificate.fabric_id == fabric.fabric_id && certificate.node_id == node_id &&
                 certificate.ec_public_key == public_key
            raise Matter::CertificateError.new("Issued NOC does not match the device CSR and fabric")
          end
        end

        # Certificates only have to be distinguishable within this fabric
        private def serial_number : Bytes
          @crypto.random_bytes(CERTIFICATE_SERIAL_BYTES)
        end

        private def assert_invoke_ok!(response : InteractionModel::InvokeResponseMessage, name : String) : Nil
          saw_any = false

          response.invoke_responses.each do |resp|
            if resp.command_data
              saw_any = true
              next
            end

            if status_ib = resp.command_status
              saw_any = true
              # Some commands use CommandStatusIB with Success and no CommandDataIB.
              return if status_ib.status.status == InteractionModel::StatusCode::Success.value
              raise Matter::CommissioningError.new("#{name} failed (status=#{status_ib.status.status})")
            end
          end

          raise Matter::ProtocolError.new("#{name} failed (empty InvokeResponse)") unless saw_any
        end

        protected def assert_commissioning_complete!(response : InteractionModel::InvokeResponseMessage) : Nil
          response.invoke_responses.each do |entry|
            if status = entry.command_status
              unless status.status.status == InteractionModel::StatusCode::Success.value
                raise Matter::CommissioningError.new("CommissioningComplete failed (status=#{status.status.status})")
              end
            end
          end
          fields = first_command_fields(response,
            Cluster::GeneralCommissioning::CMD_COMMISSIONING_COMPLETE_RESPONSE)
          result = Cluster::GeneralCommissioning::CommissioningCompleteResponse.from_slice(fields)
          unless result.error_code.ok?
            raise Matter::CommissioningError.new("CommissioningComplete failed (error=#{result.error_code} debug=#{result.debug_text})")
          end
        end

        private def first_command_fields(response : InteractionModel::InvokeResponseMessage, command_id : UInt32) : Bytes
          response.invoke_responses.each do |invoke_response|
            cmd = invoke_response.command_data
            next unless cmd
            next unless cmd.command_path.command == command_id
            fields = cmd.command_fields
            return fields ? fields.to_slice : Bytes.empty
          end
          raise Matter::ProtocolError.new("InvokeResponse missing command_data for command_id=0x#{command_id.to_s(16)}")
        end
      end
    end
  end
end
