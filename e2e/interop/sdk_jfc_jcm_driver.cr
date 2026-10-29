require "../../src/matter/controller"
require "../../examples/support/joint_fabric_administrator_device"
require "json"
require "base64"

module SdkJfcJcmDriver
  extend self

  A_FABRIC_ID       = 0xA100_u64
  A_CONTROLLER_ID   = 0xA101_u64
  A_ANCHOR_ID       = 0xA102_u64
  B_JOINED_ID       = 0xA103_u64
  A_VENDOR_ID       = 0xFFF1_u16
  JFA_ENDPOINT      =      1_u16
  OPERATION_TIMEOUT = 90.seconds

  private def store(path : String) : Matter::Controller::StateStore
    Matter::Controller::StateStore.new(Matter::Storage::YamlFile.new(path))
  end

  def setup(state_path : String, root_path : String) : Nil
    bootstrap = Matter::Controller::JointCommissioning.bootstrap_anchor_fabric(
      A_FABRIC_ID, A_CONTROLLER_ID, A_VENDOR_ID)
    store(state_path).save(Matter::Controller::State.new(fabric: bootstrap.fabric,
      commissioner_node_id: A_CONTROLLER_ID))
    File.write(root_path, bootstrap.fabric.root_cert)
    puts "A bootstrap ready"
  end

  def verify_csr(identity_path : String, csr_path : String) : Nil
    identity = JSON.parse(File.read(identity_path))
    icac = Base64.decode(identity["icac_certificate"].as_s)
    csr = File.read(csr_path).to_slice.dup
    key = Matter::Crypto::MatterCertificate.public_key_from_tlv(icac)
    Matter::Crypto::Pkcs10.verify(csr, key)
    puts "SDK CSR signature and commissioned ICAC public key verified"
  end

  private def command(path : String, request : MatterJointFabricAdministrator::Device::CommandRequest) : MatterJointFabricAdministrator::Device::CommandResult
    File.delete?(path)
    backend = Matter::Storage::YamlFile.new(path)
    backend.open
    begin
      backend.write(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION,
        "request", request.to_document)
    ensure
      backend.close if backend.open?
    end
    deadline = Time.instant + OPERATION_TIMEOUT
    loop do
      result_store = Matter::Storage::YamlFile.new(path)
      result_store.open
      result = begin
        doc = result_store.read(MatterJointFabricAdministrator::Device::COMMAND_RPC_COLLECTION, "result")
        doc.try { |value| MatterJointFabricAdministrator::Device::CommandResult.from_document(value) }
      ensure
        result_store.close if result_store.open?
      end
      return result if result && result.status != "in-progress"
      raise Matter::TimeoutError.new("JFA command timed out") if Time.instant >= deadline
      sleep 100.milliseconds
    end
  end

  private def exchange(path : String, request : MatterJointFabricAdministrator::Device::AnchorExchangeRequest) : Bytes
    File.delete?(path)
    backend = Matter::Storage::YamlFile.new(path)
    backend.open
    begin
      backend.write(MatterJointFabricAdministrator::Device::JCM_RPC_COLLECTION,
        MatterJointFabricAdministrator::Device::JCM_RPC_REQUEST, request.to_document)
    ensure
      backend.close if backend.open?
    end
    deadline = Time.instant + OPERATION_TIMEOUT
    loop do
      result_store = Matter::Storage::YamlFile.new(path)
      result_store.open
      result = begin
        doc = result_store.read(MatterJointFabricAdministrator::Device::JCM_RPC_COLLECTION,
          MatterJointFabricAdministrator::Device::JCM_RPC_RESULT)
        doc.try { |value| MatterJointFabricAdministrator::Device::AnchorExchangeResult.from_document(value) }
      ensure
        result_store.close if result_store.open?
      end
      if value = result
        return value.certificate.as(Bytes) if value.status == "ok" && value.certificate
        raise Matter::CommissioningError.new("Anchor exchange failed: #{value.error}") if value.status == "error"
      end
      raise Matter::TimeoutError.new("Anchor exchange timed out") if Time.instant >= deadline
      sleep 100.milliseconds
    end
  end

  def commission(state_path : String, a_code : String, b_code : String,
                 b_root_path : String, exchange_path : String, command_path : String,
                 result_path : String, a_port : Int32, b_port : Int32) : Nil
    state_store = store(state_path)
    fabric = state_store.load.fabric.as(Matter::Controller::FabricInfo)
    bootstrap_key = fabric.intermediate_private_key ||
                    raise Matter::ConfigurationError.new("A Anchor ICAC private key is unavailable")
    bootstrap = Matter::Controller::JointCommissioning::AnchorBootstrap.new(fabric, bootstrap_key)
    a_peer = Socket::IPAddress.new("127.0.0.1", a_port)
    b_peer = Socket::IPAddress.new(ENV["MATTER_JCM_TEST_B_HOST"]? || "127.0.0.1", b_port)
    client = Matter::Controller::Client.new(counter_lease: state_store.counter_lease(A_CONTROLLER_ID))
    begin
      issuer = ->(fabric_id : UInt64, node_id : UInt64, public_key : Bytes) do
        raise Matter::ConfigurationError.new("Wrong A fabric") unless fabric_id == A_FABRIC_ID
        bootstrap.issue_anchor_administrator_noc(node_id, public_key)
      end
      unless ENV["MATTER_JCM_TEST_SKIP_ANCHOR_COMMISSION"]? == "1"
        Matter::Controller::Commissioning::Commissioner.new(state_store, client,
          timeout: OPERATION_TIMEOUT, certificate_issuer: issuer,
          attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
            Matter::Controller::AttestationTrustStore.matter_test_fixture)).pairing_code(
          A_ANCHOR_ID, a_code, a_peer)
        puts "A Anchor commissioned"
      end

      trust = if url = ENV["MATTER_JCM_TEST_DCL_GATEWAY_URL"]?
                Matter::Controller::VidVerification::DclOperationalTrustAnchors.new(
                  Matter::Controller::VidVerification::HttpDclSource.new(url))
              else
                b_root = File.read(b_root_path).to_slice.dup
                Matter::Controller::VidVerification::StaticOperationalTrustAnchors.new(
                  {A_VENDOR_ID => [b_root]})
              end
      registrar = Matter::Controller::JointCommissioning::RemoteDatastoreRegistrar.new(
        state_store, client, fabric.fabric_id, fabric.root_public_key,
        fabric.controller_node_id, A_ANCHOR_ID, JFA_ENDPOINT)
      anchor_exchange = ->(selected : Matter::Controller::FabricInfo, node_id : UInt64, peer : Socket::IPAddress, endpoint : UInt16, key : Bytes, icac_id : UInt64) do
        raise Matter::AuthenticationError.new("Wrong JCM Anchor fabric") unless selected.fabric_id == A_FABRIC_ID
        exchange(exchange_path, MatterJointFabricAdministrator::Device::AnchorExchangeRequest.new(
          selected.fabric_id, selected.root_public_key, node_id,
          peer.address, peer.port, endpoint, key, icac_id))
      end
      anchor_finalize = ->(selected : Matter::Controller::FabricInfo, node_id : UInt64, peer : Socket::IPAddress, endpoint : UInt16, key : Bytes, _icac_id : UInt64, nonce : String) do
        raise Matter::AuthenticationError.new("Wrong JCM target") unless selected.fabric_id == A_FABRIC_ID && peer == b_peer
        result = command(command_path, MatterJointFabricAdministrator::Device::CommandRequest.new(
          "finalize-commissioning", node_id, fabric_id: selected.fabric_id,
          root_public_key: selected.root_public_key, nonce: nonce, jcm: true,
          trusted_icac_public_key_b: key, peer_admin_jfa_endpoint_id: endpoint))
        unless result.status == "ok" && result.nonce == nonce
          raise Matter::CommissioningError.new("Anchor completion failed: #{result.error}")
        end
        result.certificate || raise Matter::CommissioningError.new("Anchor handoff omitted cross-ICAC")
      end
      consent = ENV["MATTER_JCM_TEST_CONSENT"]? != "deny"
      workflow = Matter::Controller::JointCommissioning::Workflow.new(
        state_store, fabric.fabric_id, fabric.root_public_key, fabric.controller_node_id,
        1_u8, JFA_ENDPOINT, "SDK-owned joining Administrator", 1_u16, 1_u16, 3_u64, trust,
        ->(_im : Matter::Controller::ImClient, _session : Matter::Session::SecureContext, _peer : Socket::IPAddress, _joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { true },
        ->(_joiner : Matter::Controller::JointCommissioning::VerifiedJoiner) { consent },
        registrar.callback, anchor_exchange, client: client, anchor_finalize: anchor_finalize,
        node_list_check: registrar.node_list_check,
        attestation_verifier: Matter::Controller::DeviceAttestationVerifier.new(
          Matter::Controller::AttestationTrustStore.matter_test_fixture))
      if !consent
        begin
          workflow.commission(B_JOINED_ID, b_code, b_peer, defer_completion: true)
        rescue ex : Matter::CommissioningError
          unless ex.message.to_s.includes?("Joint Commissioning consent denied")
            raise ex
          end
          if state_store.load.nodes.has_key?(B_JOINED_ID)
            raise Matter::CommissioningError.new("Denied joiner was recorded in source controller state")
          end
          puts "PASS: trusted SDK joining Administrator was rejected by explicit consent denial"
          return
        end
        raise Matter::CommissioningError.new("Joint Commissioning succeeded without consent")
      end
      workflow.commission(B_JOINED_ID, b_code, b_peer, defer_completion: true)
      cross_icac = workflow.stored_icac(B_JOINED_ID).as(Bytes)
      File.write(result_path, cross_icac)
      puts "B JCM CommissioningComplete acknowledged with cross-ICAC"

      session = Matter::Controller::Pairing::CasePairing.new.pair(client, a_peer, fabric,
        peer_node_id: A_ANCHOR_ID, timeout: OPERATION_TIMEOUT)
      report = Matter::Controller::ImClient.new(client, OPERATION_TIMEOUT).read_attribute(
        session: session, peer: a_peer, endpoint_id: JFA_ENDPOINT,
        cluster_id: Matter::Cluster::JointFabricDatastore::CLUSTER_ID,
        attribute_id: Matter::Cluster::JointFabricDatastore::ATTR_ADMIN_LIST)
      data = report.attribute_reports.as(Array(Matter::InteractionModel::AttributeReportIB))
        .first.attribute_data.as(Matter::InteractionModel::AttributeDataIB).data.as(TLV::Any)
      admins = Array(Matter::Cluster::JointFabricDatastore::DatastoreAdministratorInformationEntryStruct)
        .from_tlv(data.to_slice)
      registered = admins.find(&.node_id.==(B_JOINED_ID)) ||
                   raise Matter::CommissioningError.new("A Datastore omitted B Administrator")
      unless registered.icac == cross_icac
        raise Matter::CertificateError.new("A Datastore cross-ICAC differs from completed handoff")
      end
      puts "A Datastore registered B with the completed cross-ICAC"
    ensure
      client.close
    end
  end

  def probe_dcl(b_code : String, b_port : Int32, gateway_url : String,
                expected : String) : Nil
    _, pin = Matter::SetupPayload.parse_manual_code(b_code)
    peer = Socket::IPAddress.new(ENV["MATTER_JCM_TEST_B_HOST"]? || "127.0.0.1", b_port)
    client = Matter::Controller::Client.new
    begin
      session = Matter::Controller::Pairing::PasePairing.new.pair(client, peer, pin,
        timeout: OPERATION_TIMEOUT)
      client.register_session(session)
      im = Matter::Controller::ImClient.new(client, OPERATION_TIMEOUT)
      index = Matter::Controller::JointCommissioning.read_administrator_fabric_index(
        im, session, peer, JFA_ENDPOINT)
      trust = Matter::Controller::VidVerification::DclOperationalTrustAnchors.new(
        Matter::Controller::VidVerification::HttpDclSource.new(gateway_url))
      begin
        Matter::Controller::JointCommissioning.verify_joiner(im, session, peer, index, trust)
      rescue ex : Matter::AuthenticationError
        raise ex unless expected == "deny"
        puts "PASS: SDK joining Administrator denied by test DCL before Joint Commissioning: #{ex.message}"
        return
      end
      raise Matter::AuthenticationError.new("Untrusted SDK joining Administrator passed DCL validation") if expected == "deny"
      puts "PASS: SDK joining Administrator and VID accepted by test DCL before Joint Commissioning"
    ensure
      client.close
    end
  end
end

case ARGV.shift?
when "setup"
  SdkJfcJcmDriver.setup(ARGV[0], ARGV[1])
when "verify-csr"
  SdkJfcJcmDriver.verify_csr(ARGV[0], ARGV[1])
when "commission"
  SdkJfcJcmDriver.commission(ARGV[0], ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5],
    ARGV[6], ARGV[7].to_i, ARGV[8].to_i)
when "probe-dcl"
  SdkJfcJcmDriver.probe_dcl(ARGV[0], ARGV[1].to_i, ARGV[2], ARGV[3])
else
  STDERR.puts "Usage: sdk_jfc_jcm_driver {setup|verify-csr|commission|probe-dcl} ..."
  exit 2
end
