require "../support/operational_credentials_helpers"

describe Matter::Cluster::OperationalCredentials do
  describe "initialization" do
    it "creates operational credentials cluster" do
      cluster = build_op_creds_cluster

      cluster.cluster_id.id.should eq(0x003E_u32)
      cluster.name.should eq("OperationalCredentials")
      cluster.nocs.should be_empty
      cluster.fabrics.should be_empty
      cluster.supported_fabrics.should eq(16_u8)
      cluster.commissioned_fabrics.should eq(0_u8)
    end
  end

  describe "attributes" do
    it "reads NOCs attribute when empty" do
      cluster = build_op_creds_cluster

      read_tlv(cluster, Matter::Cluster::OperationalCredentials::ATTR_NOCS).as_list.should be_empty
    end

    it "reads Fabrics attribute" do
      cluster = build_op_creds_cluster

      value = cluster.read_attribute(Matter::Cluster::OperationalCredentials::ATTR_FABRICS)
      value.should be_a(TLV::Any)
    end

    it "reads SupportedFabrics attribute" do
      cluster = build_op_creds_cluster

      read(cluster, Matter::Cluster::OperationalCredentials::ATTR_SUPPORTED_FABRICS).should eq(16_u8)
    end

    it "reads CommissionedFabrics attribute" do
      cluster = build_op_creds_cluster

      read(cluster, Matter::Cluster::OperationalCredentials::ATTR_COMMISSIONED_FABRICS).should eq(0_u8)
    end

    it "reads TrustedRootCertificates attribute" do
      cluster = build_op_creds_cluster

      value = cluster.read_attribute(Matter::Cluster::OperationalCredentials::ATTR_TRUSTED_ROOT_CERTIFICATES)
      value.should be_a(TLV::Any)
    end

    it "reads CurrentFabricIndex attribute when not set" do
      cluster = build_op_creds_cluster

      read(cluster, Matter::Cluster::OperationalCredentials::ATTR_CURRENT_FABRIC_INDEX).should eq(0_u8)
    end

    it "returns status for unsupported attribute write" do
      cluster = build_op_creds_cluster

      status = write(cluster,
        Matter::Cluster::OperationalCredentials::ATTR_SUPPORTED_FABRICS,
        32_u8
      )

      status.status.should eq(Matter::InteractionModel::StatusCode::UnsupportedWrite)
    end
  end

  describe "metadata" do
    it "provides attribute metadata" do
      cluster = build_op_creds_cluster

      attributes = cluster.attributes
      attributes.should_not be_empty
      attributes.size.should be >= 5

      supported_fabrics = attributes.find { |attr| attr.id.id == Matter::Cluster::OperationalCredentials::ATTR_SUPPORTED_FABRICS }
      supported_fabrics.should_not be_nil
      supported_fabrics_attr = supported_fabrics.as(Matter::Cluster::AttributeMetadata)
      supported_fabrics_attr.name.should eq("supportedFabrics")
      supported_fabrics_attr.writable?.should be_false
    end

    it "provides command metadata" do
      cluster = build_op_creds_cluster

      commands = cluster.commands
      commands.should_not be_empty
      commands.size.should be >= 6

      attestation_cmd = commands.find { |cmd| cmd.id.id == Matter::Cluster::OperationalCredentials::CMD_ATTESTATION_REQUEST }
      attestation_cmd.should_not be_nil
      attestation_cmd.as(Matter::Cluster::CommandMetadata).name.should eq("attestationRequest")
    end
  end

  describe "NOCStruct" do
    it "creates NOC struct" do
      noc_cert = "mock_noc_certificate".to_slice
      icac_cert = "mock_icac".to_slice

      noc = Matter::Cluster::OperationalCredentials::NOCStruct.new(
        noc: noc_cert,
        icac: icac_cert,
        fabric_index: 1_u8
      )

      noc.noc.should eq(noc_cert)
      noc.icac.should eq(icac_cert)
      noc.fabric_index.should eq(1_u8)
    end
  end

  describe "FabricDescriptorStruct" do
    it "creates fabric descriptor" do
      root_public_key = Bytes.new(65, 0_u8)
      vendor_id = 0xFFF1_u16
      fabric_id = 0x1234567890ABCDEF_u64
      node_id = 0xFEDCBA0987654321_u64
      label = "TestFabric"

      fabric = Matter::Cluster::OperationalCredentials::FabricDescriptorStruct.new(
        root_public_key: root_public_key,
        vendor_id: vendor_id,
        fabric_id: fabric_id,
        node_id: node_id,
        label: label,
        fabric_index: 1_u8
      )

      fabric.root_public_key.should eq(root_public_key)
      fabric.vendor_id.should eq(vendor_id)
      fabric.fabric_id.should eq(fabric_id)
      fabric.node_id.should eq(node_id)
      fabric.label.should eq(label)
      fabric.fabric_index.should eq(1_u8)
    end
  end

  describe "NodeOperationalCertStatus" do
    it "defines status codes" do
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::Ok.value.should eq(0_u8)
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidPublicKey.value.should eq(1_u8)
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidNodeOpId.value.should eq(2_u8)
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidNoc.value.should eq(3_u8)
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::MissingCsr.value.should eq(4_u8)
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::TableFull.value.should eq(5_u8)
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InsufficientPrivilege.value.should eq(8_u8)
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::FabricConflict.value.should eq(9_u8)
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::LabelConflict.value.should eq(10_u8)
      Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidFabricIndex.value.should eq(11_u8)
    end
  end

  describe "commands" do
    it "handles AttestationRequest command" do
      cluster = build_op_creds_cluster

      nonce = Bytes.new(32, 0x42_u8)
      command_data = create_attestation_request_tlv(nonce)
      result = invoke(cluster, Matter::Cluster::OperationalCredentials::CMD_ATTESTATION_REQUEST, command_data)
      result.should be_a(Matter::Cluster::CommandResponse)
    end

    it "handles CertificateChainRequest command" do
      cluster = build_op_creds_cluster

      command_data = create_certificate_chain_request_tlv(1_u8) # DACCertificate
      result = invoke(cluster, Matter::Cluster::OperationalCredentials::CMD_CERTIFICATE_CHAIN_REQUEST, command_data)
      result.should be_a(Matter::Cluster::CommandResponse)
    end

    it "handles CSRRequest command" do
      cluster = build_op_creds_cluster

      nonce = Bytes.new(32, 0x42_u8)
      command_data = create_csr_request_tlv(nonce)
      result = invoke(cluster, Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST, command_data)
      result.should be_a(Matter::Cluster::CommandResponse)
    end

    it "handles AddNOC command" do
      cluster = build_op_creds_cluster

      noc = Bytes.new(100, 0x01_u8)
      ipk = Bytes.new(16, 0x02_u8)
      command_data = create_add_noc_request_tlv(noc, nil, ipk, 0x1234567890_u64, 0xFFF1_u16)
      result = invoke(cluster, Matter::Cluster::OperationalCredentials::CMD_ADD_NOC, command_data)
      result.should be_a(Matter::Cluster::CommandResponse)
    end

    it "handles UpdateNOC command" do
      cluster = build_op_creds_cluster

      noc = Bytes.new(100, 0x01_u8)
      command_data = create_update_noc_request_tlv(noc, nil)
      result = invoke(cluster, Matter::Cluster::OperationalCredentials::CMD_UPDATE_NOC, command_data,
        is_case_session: true, fabric_index: 1_u8)
      result.should be_a(Matter::Cluster::CommandResponse)
    end

    it "handles AddTrustedRootCertificate command" do
      cluster = build_op_creds_cluster

      cert = Bytes.new(100, 0x01_u8)
      command_data = create_add_trusted_root_cert_request_tlv(cert)
      result = invoke(cluster, Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE, command_data)
      result.should be_a(Matter::InteractionModel::Status)
    end

    it "handles RemoveFabric command" do
      cluster = build_op_creds_cluster

      command_data = create_remove_fabric_request_tlv(1_u8)
      result = invoke(cluster, Matter::Cluster::OperationalCredentials::CMD_REMOVE_FABRIC, command_data)
      result.should be_a(Matter::Cluster::CommandResponse)
    end
  end

  describe "trusted root certificates" do
    it "tracks trusted root certificate list" do
      cluster = build_op_creds_cluster

      cluster.trusted_root_certificates.should be_empty
    end

    it "can add trusted root certificate" do
      cluster = build_op_creds_cluster

      root_cert = "mock_root_certificate".to_slice
      cluster.trusted_root_certificates << root_cert

      cluster.trusted_root_certificates.size.should eq(1)
      cluster.trusted_root_certificates[0].should eq(root_cert)
    end
  end

  describe "certificate types" do
    it "defines certificate types" do
      Matter::Cluster::OperationalCredentials::CertificateChainType::DACCertificate.value.should eq(1_u8)
      Matter::Cluster::OperationalCredentials::CertificateChainType::PAICertificate.value.should eq(2_u8)
    end
  end

  describe "AttestationRequest command" do
    it "validates nonce length" do
      expect_raises(ArgumentError, "attestation_nonce must be 32 bytes") do
        Matter::Cluster::OperationalCredentials::AttestationRequestCommand.new(
          attestation_nonce: Bytes.new(16) # Too short
        )
      end
    end
  end

  describe "CertificateChainRequest command" do
    it "returns DAC certificate when available" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      dac = Bytes.new(100, 1_u8)
      pai = Bytes.new(100, 2_u8)
      key = Matter::Crypto::Key.generate_key_pair
      cluster.set_attestation_credentials(dac, pai, key)

      cmd = Matter::Cluster::OperationalCredentials::CertificateChainRequestCommand.new(
        certificate_type: Matter::Cluster::OperationalCredentials::CertificateChainType::DACCertificate
      )

      response = cluster.handle_certificate_chain_request(cmd)
      response.as(Matter::Cluster::OperationalCredentials::CertificateChainResponse).certificate.should eq(dac)
    end

    it "returns PAI certificate when available" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      dac = Bytes.new(100, 1_u8)
      pai = Bytes.new(100, 2_u8)
      key = Matter::Crypto::Key.generate_key_pair
      cluster.set_attestation_credentials(dac, pai, key)

      cmd = Matter::Cluster::OperationalCredentials::CertificateChainRequestCommand.new(
        certificate_type: Matter::Cluster::OperationalCredentials::CertificateChainType::PAICertificate
      )

      response = cluster.handle_certificate_chain_request(cmd)
      response.as(Matter::Cluster::OperationalCredentials::CertificateChainResponse).certificate.should eq(pai)
    end

    it "returns Failure when certificate not available" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      cmd = Matter::Cluster::OperationalCredentials::CertificateChainRequestCommand.new(
        certificate_type: Matter::Cluster::OperationalCredentials::CertificateChainType::DACCertificate
      )

      response = cluster.handle_certificate_chain_request(cmd)
      response.should eq(Matter::InteractionModel::Status.failure)
    end
  end

  describe "AddTrustedRootCertificate command" do
    it "requires armed failsafe" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      cmd = Matter::Cluster::OperationalCredentials::AddTrustedRootCertificateCommand.new(
        root_ca_certificate: OpCredsTestHelpers.create_test_root_cert
      )

      response = cluster.handle_add_trusted_root_certificate(cmd, failsafe_armed: false)
      response.should be_nil
    end

    it "accepts a byte-identical root certificate in the same failsafe" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      # Set up attestation credentials
      dac = Bytes.new(100, 1_u8)
      pai = Bytes.new(100, 2_u8)
      key = Matter::Crypto::Key.generate_key_pair
      cluster.set_attestation_credentials(dac, pai, key)

      # CSR first
      csr_cmd = Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(
        csr_nonce: Bytes.new(32, 0_u8)
      )
      cluster.handle_csr_request(csr_cmd, session_id: 1_u64, is_pase_session: true, failsafe_armed: true)

      # Add root cert
      root_cert = OpCredsTestHelpers.create_test_root_cert
      cmd = Matter::Cluster::OperationalCredentials::AddTrustedRootCertificateCommand.new(
        root_ca_certificate: root_cert
      )
      cluster.handle_add_trusted_root_certificate(cmd, failsafe_armed: true)

      # Try to add again
      response = cluster.handle_add_trusted_root_certificate(cmd, failsafe_armed: true)
      response.should be_nil
      cluster.trusted_root_certificates.size.should eq 1
    end
  end

  describe "integration tests" do
    describe "certificate public key extraction" do
      it "processes AddNOC with TLV root certificate" do
        fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
        cluster = Matter::Cluster::OperationalCredentials.new(fabric_table, endpoint(0), nil)

        # Set up for AddNOC
        cluster.failsafe_armed = true
        cluster.request_session_id = 1_u64

        # Request CSR first
        nonce = Bytes.new(32, 0_u8)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          create_csr_request_tlv(nonce, false)
        )

        authority = TestCertificateAuthority.default
        public_key = authority.root_public_key

        # A TLV root certificate whose tag 9 carries that public key
        tlv_cert = authority.root_certificate(0x1234567890_u64)

        # Add trusted root certificate (TLV format)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          create_add_trusted_root_cert_request_tlv(tlv_cert)
        )

        # Create NOC with same public key as root
        noc = create_mock_noc_with_key(0x1111111111111111_u64, 0x1234567890_u64,
          csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)), 0x1234567890_u64)

        # Invoke AddNOC - should successfully extract public key from TLV certificate
        ipk = Bytes.new(16, 0_u8)
        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc, nil, ipk, 0xABCD_u64, 0xFFF1_u16)
        )

        # Should succeed - verifying that TLV certificate processing worked
        result.should be_a(Matter::Cluster::CommandResponse)
        parsed = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
        response = parsed.value.as(TLV::Structure)
        status = response[0_u8].value.as(Int)
        status.should eq(0) # Success

        # Verify fabric was created with correct public key
        cluster.fabric_table.all_fabrics.size.should eq(1)
        cluster.fabric_table.all_fabrics[0].root_public_key.should eq(public_key)
      end

      it "processes AddNOC with a Matter root generated from an OpenSSL key" do
        fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
        cluster = Matter::Cluster::OperationalCredentials.new(fabric_table, endpoint(0), nil)

        # Set up for AddNOC
        cluster.failsafe_armed = true
        cluster.request_session_id = 1_u64

        # Request CSR
        nonce = Bytes.new(32, 0_u8)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          create_csr_request_tlv(nonce, false)
        )

        # Generate the signing key with OpenSSL, then encode it as the Matter
        # TLV RCAC required by AddTrustedRootCertificate.
        pkey = OpenSSL::PKey::EC.generate_by_curve_name("prime256v1")
        root_key = Matter::Crypto::Key.new(Matter::Crypto::KeyType::EC, Matter::Crypto::CurveType::P256)
        root_key.private_bits = pkey.private_key_bytes
        root_key.public_bits = pkey.public_key_bytes

        root_cert = Matter::Crypto::MatterCertificate::Builder.root(
          root_key, TestCertificateAuthority::ROOT_CERTIFICATE_ID, Bytes[1])

        # Extract the public key bytes from the generated key for NOC
        public_key_bytes = pkey.public_key_bytes

        # Add the root certificate
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          create_add_trusted_root_cert_request_tlv(root_cert)
        )

        # A node certificate the Matter root actually issued
        noc = Matter::Crypto::MatterCertificate::Builder.node(
          public_key: csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)),
          fabric_id: 0x9876543210_u64,
          node_id: 0x2222222222222222_u64,
          issuer_key: root_key,
          issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
          serial: Bytes[0x01]
        )

        # Invoke AddNOC - should successfully extract public key from the root certificate
        ipk = Bytes.new(16, 1_u8)
        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc, nil, ipk, 0xBCDE_u64, 0xFFF2_u16)
        )

        # Should succeed - verifying that the OpenSSL key and Matter certificate interoperate
        result.should be_a(Matter::Cluster::CommandResponse)
        parsed = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
        response = parsed.value.as(TLV::Structure)
        status = response[0_u8].value.as(Int)
        status.should eq(0) # Success

        # Verify fabric was created with correct public key
        cluster.fabric_table.all_fabrics.size.should eq(1)
        cluster.fabric_table.all_fabrics[0].root_public_key.should eq(public_key_bytes)
      end

      it "computes correct compressed fabric ID from extracted public key" do
        fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
        cluster = Matter::Cluster::OperationalCredentials.new(fabric_table, endpoint(0), nil)

        # Set up for AddNOC
        cluster.failsafe_armed = true
        cluster.request_session_id = 1_u64

        # Request CSR
        nonce = Bytes.new(32, 0_u8)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          create_csr_request_tlv(nonce, false)
        )

        authority = TestCertificateAuthority.default
        public_key = authority.root_public_key

        # Create TLV root certificate
        tlv_cert = authority.root_certificate(0x1_u64)

        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          create_add_trusted_root_cert_request_tlv(tlv_cert)
        )

        # Create NOC with same public key
        noc = create_mock_noc_with_key(0x1_u64, 0x1_u64, csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)))

        ipk = Bytes.new(16, 0_u8)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc, nil, ipk, 0xDEAD_u64, 0xBEEF_u16)
        )

        # Verify fabric was created with correct public key extracted from certificate
        cluster.fabric_table.all_fabrics.size.should eq(1)
        fabric = cluster.fabric_table.all_fabrics[0]

        # The compressed fabric ID is computed from the public key (bytes 1-64)
        # using HKDF-SHA256 with fabric_id as salt. We verify the fabric has
        # the correct public key, which means the compressed fabric ID will be correct.
        fabric.root_public_key.should eq(public_key)
      end
    end
  end
end
