require "../spec_helper"

private alias FabricTlsCert = Matter::Cluster::TlsCertificateManagement
private alias FabricTlsStatus = Matter::InteractionModel::StatusCode

describe "TLS Certificate Management fabric-scoped commands" do
  [Matter::DataType::NO_FABRIC, UInt8::MAX].each do |invalid_fabric|
    it "rejects every command on reserved fabric #{invalid_fabric} before hooks and state changes" do
      cluster = build(FabricTlsCert)
      hooks = 0
      persists = 0
      cluster.on_before_command = ->(_command : UInt32) { hooks += 1; nil }
      cluster.on_persist = -> { persists += 1; nil }
      before_state = cluster.save_state
      before_version = cluster.data_version

      results = [
        invoke(cluster, FabricTlsCert::CMD_PROVISION_ROOT_CERTIFICATE,
          FabricTlsCert::Tlv::ProvisionRootCertificateRequest.new(Bytes[1], nil),
          is_case_session: true, fabric_index: invalid_fabric),
        invoke(cluster, FabricTlsCert::CMD_FIND_ROOT_CERTIFICATE,
          FabricTlsCert::Tlv::FindRootCertificateRequest.new(nil),
          is_case_session: true, fabric_index: invalid_fabric),
        invoke(cluster, FabricTlsCert::CMD_LOOKUP_ROOT_CERTIFICATE,
          FabricTlsCert::Tlv::LookupRootCertificateRequest.new(Bytes[1]),
          is_case_session: true, fabric_index: invalid_fabric),
        invoke(cluster, FabricTlsCert::CMD_REMOVE_ROOT_CERTIFICATE,
          FabricTlsCert::Tlv::RemoveRootCertificateRequest.new(0_u16),
          is_case_session: true, fabric_index: invalid_fabric),
        invoke(cluster, FabricTlsCert::CMD_CLIENT_CSR,
          FabricTlsCert::Tlv::ClientCsrRequest.new(Bytes.new(FabricTlsCert::NONCE_BYTES, 1_u8), nil),
          is_case_session: true, fabric_index: invalid_fabric),
        invoke(cluster, FabricTlsCert::CMD_PROVISION_CLIENT_CERTIFICATE,
          FabricTlsCert::Tlv::ProvisionClientCertificateRequest.new(0_u16, Bytes[1], [] of Bytes),
          is_case_session: true, fabric_index: invalid_fabric),
        invoke(cluster, FabricTlsCert::CMD_FIND_CLIENT_CERTIFICATE,
          FabricTlsCert::Tlv::FindClientCertificateRequest.new(nil),
          is_case_session: true, fabric_index: invalid_fabric),
        invoke(cluster, FabricTlsCert::CMD_LOOKUP_CLIENT_CERTIFICATE,
          FabricTlsCert::Tlv::LookupClientCertificateRequest.new(Bytes[1]),
          is_case_session: true, fabric_index: invalid_fabric),
        invoke(cluster, FabricTlsCert::CMD_REMOVE_CLIENT_CERTIFICATE,
          FabricTlsCert::Tlv::RemoveClientCertificateRequest.new(0_u16),
          is_case_session: true, fabric_index: invalid_fabric),
      ]

      results.each { |result| expect_status(result, FabricTlsStatus::UnsupportedAccess) }
      hooks.should eq(0)
      persists.should eq(0)
      cluster.save_state.should eq(before_state)
      cluster.data_version.should eq(before_version)
    end
  end

  [Matter::Fabric::MIN_FABRIC_INDEX, Matter::Fabric::MAX_FABRIC_INDEX].each do |valid_fabric|
    it "preserves valid CASE access on fabric #{valid_fabric}" do
      cluster = build(FabricTlsCert)
      expect_status(invoke(cluster, FabricTlsCert::CMD_FIND_ROOT_CERTIFICATE,
        FabricTlsCert::Tlv::FindRootCertificateRequest.new(nil),
        is_case_session: true, fabric_index: valid_fabric), FabricTlsStatus::NotFound)
    end
  end
end
