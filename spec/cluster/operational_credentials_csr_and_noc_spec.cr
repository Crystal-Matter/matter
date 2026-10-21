require "../support/operational_credentials_helpers"

describe Matter::Cluster::OperationalCredentials do
  describe "NOC management" do
    it "tracks NOC list" do
      cluster = build_op_creds_cluster

      cluster.nocs.should be_empty
    end

    it "finds NOC by fabric index" do
      cluster = build_op_creds_cluster

      noc = cluster.get_noc_by_fabric_index(1_u8)
      noc.should be_nil
    end
  end

  describe "CSRRequest command" do
    it "validates nonce length" do
      expect_raises(ArgumentError, "csr_nonce must be 32 bytes") do
        Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(
          csr_nonce: Bytes.new(16) # Too short
        )
      end
    end

    it "requires armed failsafe" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      nonce = Bytes.new(32, 0_u8)
      cmd = Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(
        csr_nonce: nonce
      )

      response = cluster.handle_csr_request(
        cmd,
        session_id: 1_u64,
        is_pase_session: true,
        failsafe_armed: false
      )

      response.should be_nil
    end

    it "rejects update NOC request on PASE session" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      nonce = Bytes.new(32, 0_u8)
      cmd = Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(
        csr_nonce: nonce,
        is_for_update_noc: true
      )

      response = cluster.handle_csr_request(
        cmd,
        session_id: 1_u64,
        is_pase_session: true, # PASE session
        failsafe_armed: true
      )

      response.should be_nil
    end
  end

  describe "AddNOC command" do
    it "rejects a NOC after its certificate validity interval" do
      authority = TestCertificateAuthority.default
      cluster = build_op_creds_cluster
      cluster.set_attestation_credentials(Bytes.new(100, 1_u8), Bytes.new(100, 2_u8),
        Matter::Crypto::Key.generate_key_pair)
      csr = cluster.handle_csr_request(
        Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(csr_nonce: Bytes.new(32)),
        session_id: 1_u64, is_pase_session: true, failsafe_armed: true).as(Matter::Cluster::OperationalCredentials::CSRResponse)
      cluster.handle_add_trusted_root_certificate(
        Matter::Cluster::OperationalCredentials::AddTrustedRootCertificateCommand.new(
          root_ca_certificate: authority.root_certificate), failsafe_armed: true)
      noc = authority.issue(TestCertificateAuthority::DEFAULT_FABRIC_ID,
        TestCertificateAuthority::DEFAULT_NODE_ID, csr_public_key(csr))
      request = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
        noc_value: noc, icac_value: nil, ipk_value: Bytes.new(16),
        case_admin_subject: 1_u64, admin_vendor_id: 0xFFF1_u16)

      Timecop.travel(Time.utc + 11.years) do
        outcome = cluster.handle_add_noc(request, session_id: 1_u64, failsafe_armed: true)
        outcome.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidNoc)
      end
    end

    it "rejects a NOC chained through an ICAC for another fabric" do
      authority = TestCertificateAuthority.default
      cluster = build_op_creds_cluster
      cluster.set_attestation_credentials(Bytes.new(100, 1_u8), Bytes.new(100, 2_u8),
        Matter::Crypto::Key.generate_key_pair)
      csr = cluster.handle_csr_request(
        Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(csr_nonce: Bytes.new(32)),
        session_id: 1_u64, is_pase_session: true, failsafe_armed: true).as(Matter::Cluster::OperationalCredentials::CSRResponse)
      cluster.handle_add_trusted_root_certificate(
        Matter::Cluster::OperationalCredentials::AddTrustedRootCertificateCommand.new(
          root_ca_certificate: authority.root_certificate), failsafe_armed: true)
      intermediate_key = Matter::Crypto::Key.generate_key_pair
      icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
        public_key: intermediate_key.public_key,
        fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID + 1_u64,
        icac_id: 2_u64, issuer_key: authority.key,
        issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
        serial: Bytes.new(TestCertificateAuthority::SERIAL_BYTES, 1_u8))
      noc = Matter::Crypto::MatterCertificate::Builder.node(
        public_key: csr_public_key(csr),
        fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID,
        node_id: TestCertificateAuthority::DEFAULT_NODE_ID,
        issuer_key: intermediate_key,
        issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
        issuer_icac_id: 2_u64,
        serial: Bytes.new(TestCertificateAuthority::SERIAL_BYTES, 2_u8))
      request = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
        noc_value: noc, icac_value: icac, ipk_value: Bytes.new(16),
        case_admin_subject: 1_u64, admin_vendor_id: 0xFFF1_u16)

      outcome = cluster.handle_add_noc(request, session_id: 1_u64, failsafe_armed: true)
      outcome.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidNoc)
    end

    it "rejects an ICAC whose KeyUsage excludes keyCertSign" do
      authority = TestCertificateAuthority.default
      cluster = build_op_creds_cluster
      cluster.set_attestation_credentials(Bytes.new(100, 1_u8), Bytes.new(100, 2_u8),
        Matter::Crypto::Key.generate_key_pair)
      csr = cluster.handle_csr_request(
        Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(csr_nonce: Bytes.new(32)),
        session_id: 1_u64, is_pase_session: true, failsafe_armed: true).as(Matter::Cluster::OperationalCredentials::CSRResponse)
      cluster.handle_add_trusted_root_certificate(
        Matter::Cluster::OperationalCredentials::AddTrustedRootCertificateCommand.new(
          root_ca_certificate: authority.root_certificate), failsafe_armed: true)
      intermediate_key = Matter::Crypto::Key.generate_key_pair
      icac = Matter::Crypto::MatterCertificate::Builder.intermediate(
        public_key: intermediate_key.public_key,
        fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID,
        icac_id: 2_u64, issuer_key: authority.key,
        issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
        serial: Bytes.new(TestCertificateAuthority::SERIAL_BYTES, 1_u8))
      fields = TLV::Any.from_slice(icac).as_structure
      usage_tag = Matter::Crypto::MatterCertificate::Asn1::Extension::KeyUsage.value
      extensions = fields[Matter::Crypto::MatterCertificate::Asn1::Field::Extensions.value].as_list
      index = extensions.index { |extension| extension.header.ids == usage_tag }.as(Int32)
      extensions[index] = TLV::Any.new(1_u16, usage_tag)
      unsigned = Matter::Crypto::MatterCertificate::Asn1.to_unsigned_asn1(TLV::Any.new(fields, nil))
      fields[Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value] = TLV::Any.new(
        Matter::Crypto::StandardCrypto.new.sign_ecdsa(authority.key, unsigned),
        Matter::Crypto::MatterCertificate::Asn1::Field::Signature.value)
      restricted_icac = TLV::Any.new(fields, nil).to_slice
      noc = Matter::Crypto::MatterCertificate::Builder.node(
        public_key: csr_public_key(csr),
        fabric_id: TestCertificateAuthority::DEFAULT_FABRIC_ID,
        node_id: TestCertificateAuthority::DEFAULT_NODE_ID,
        issuer_key: intermediate_key,
        issuer_rcac_id: TestCertificateAuthority::ROOT_CERTIFICATE_ID,
        issuer_icac_id: 2_u64,
        serial: Bytes.new(TestCertificateAuthority::SERIAL_BYTES, 2_u8))
      request = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
        noc_value: noc, icac_value: restricted_icac, ipk_value: Bytes.new(16),
        case_admin_subject: 1_u64, admin_vendor_id: 0xFFF1_u16)

      outcome = cluster.handle_add_noc(request, session_id: 1_u64, failsafe_armed: true)
      outcome.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidNoc)
    end

    it "validates IPK length" do
      expect_raises(ArgumentError, "ipk_value must be 16 bytes") do
        Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
          noc_value: Bytes.new(100),
          icac_value: nil,
          ipk_value: Bytes.new(8), # Too short
          case_admin_subject: 1_u64,
          admin_vendor_id: 0xFFF1_u16
        )
      end
    end

    it "requires armed failsafe" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      cmd = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
        noc_value: Bytes.new(100),
        icac_value: nil,
        ipk_value: Bytes.new(16),
        case_admin_subject: 1_u64,
        admin_vendor_id: 0xFFF1_u16
      )

      response = cluster.handle_add_noc(cmd, session_id: 1_u64, failsafe_armed: false)
      response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidNoc)
    end

    it "creates default ACL entry when AccessControl is available" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      acl_cluster = build(Matter::Cluster::AccessControl, 0)
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table, acl_cluster)

      # Set up attestation credentials
      dac = Bytes.new(100, 1_u8)
      pai = Bytes.new(100, 2_u8)
      key = Matter::Crypto::Key.generate_key_pair
      cluster.set_attestation_credentials(dac, pai, key)

      # CSR
      csr_cmd = Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(
        csr_nonce: Bytes.new(32, 0_u8)
      )
      csr_result = cluster.handle_csr_request(csr_cmd, session_id: 1_u64, is_pase_session: true, failsafe_armed: true)

      # Root cert
      root_cmd = Matter::Cluster::OperationalCredentials::AddTrustedRootCertificateCommand.new(
        root_ca_certificate: OpCredsTestHelpers.create_test_root_cert
      )
      cluster.handle_add_trusted_root_certificate(root_cmd, failsafe_armed: true)

      # AddNOC with valid TLV-encoded NOC
      noc = TestCertificateAuthority.default.issue(
        0x1234567890_u64, 0xABCDEF_u64, csr_public_key(csr_result.as(Matter::Cluster::OperationalCredentials::CSRResponse))
      )
      admin_subject = 0x9999_u64
      cmd = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
        noc_value: noc,
        icac_value: nil,
        ipk_value: Bytes.new(16),
        case_admin_subject: admin_subject,
        admin_vendor_id: 0xFFF1_u16
      )

      # Verify no ACL entries before
      acl_cluster.acl.size.should eq(0)

      response = cluster.handle_add_noc(cmd, session_id: 1_u64, failsafe_armed: true)
      response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::Ok)

      # Verify default ACL entry was created
      acl_cluster.acl.size.should eq(1)
      acl_entry = acl_cluster.acl.first
      acl_entry.privilege.should eq(Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer)
      acl_entry.auth_mode.should eq(Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE)
      acl_entry.subjects.should eq([admin_subject])
      acl_entry.targets.should be_nil # All targets
      acl_entry.fabric_index.should eq(response.fabric_index)
    end

    it "rejects when table is full" do
      fabric_table = OpCredsTestHelpers.create_fabric_table(max_fabrics: 5_u8)
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      # Set up attestation credentials
      dac = Bytes.new(100, 1_u8)
      pai = Bytes.new(100, 2_u8)
      key = Matter::Crypto::Key.generate_key_pair
      cluster.set_attestation_credentials(dac, pai, key)

      # Fill table
      (1..5).each do |i|
        fabric = OpCredsTestHelpers.create_test_fabric(i.to_u64, i.to_u8)
        fabric_table.add_fabric(fabric)
      end

      cluster.commissioned_fabrics.should eq(5)

      # Try to add another
      csr_cmd = Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(
        csr_nonce: Bytes.new(32, 0_u8)
      )
      cluster.handle_csr_request(csr_cmd, session_id: 1_u64, is_pase_session: true, failsafe_armed: true)

      root_cmd = Matter::Cluster::OperationalCredentials::AddTrustedRootCertificateCommand.new(
        root_ca_certificate: OpCredsTestHelpers.create_test_root_cert
      )
      cluster.handle_add_trusted_root_certificate(root_cmd, failsafe_armed: true)

      cmd = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
        noc_value: Bytes.new(100),
        icac_value: nil,
        ipk_value: Bytes.new(16),
        case_admin_subject: 1_u64,
        admin_vendor_id: 0xFFF1_u16
      )

      response = cluster.handle_add_noc(cmd, session_id: 1_u64, failsafe_armed: true)
      response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::TableFull)
    end
  end

  describe "integration tests" do
    describe "full commissioning flow" do
      it "completes CSR → AddTrustedRoot → AddNOC flow" do
        cluster = build_op_creds_cluster

        # Set session context for integration test
        cluster.request_session_id = 12345_u64
        cluster.failsafe_armed = true

        # Step 1: Generate CSR
        nonce = Bytes.new(32, 0x42_u8)
        csr_request_tlv = create_csr_request_tlv(nonce, false)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          csr_request_tlv
        )
        csr_result.should be_a(Matter::Cluster::CommandResponse)
        csr_result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any).to_slice.size.should be > 0

        # Step 2: Add trusted root certificate
        # Create a valid TLV certificate with a public key
        authority = TestCertificateAuthority.default

        root_cert = authority.root_certificate
        add_root_tlv = create_add_trusted_root_cert_request_tlv(root_cert)
        root_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          add_root_tlv
        )
        # AddTrustedRootCertificate returns Status, not CommandResponse
        root_result.should be_a(Matter::InteractionModel::Status)
        root_result.as(Matter::InteractionModel::Status).status.should eq(Matter::InteractionModel::StatusCode::Success)

        # Verify root cert was added
        cluster.trusted_root_certificates.size.should eq(1)

        # Step 3: Create a mock NOC with embedded fabric_id and node_id
        noc_bytes = create_mock_noc_with_key(0x1234567890ABCDEF_u64, 0x0011223344556677_u64, csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)))

        # Step 4: Add NOC
        ipk = Bytes.new(16, 0x02_u8)
        add_noc_tlv = create_add_noc_request_tlv(
          noc_bytes,
          nil,
          ipk,
          0xABCDEF0123456789_u64,
          0xFFF1_u16
        )
        noc_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          add_noc_tlv
        )
        noc_result.should be_a(Matter::Cluster::CommandResponse)

        # Verify fabric was added
        cluster.commissioned_fabrics.should eq(1_u8)
        cluster.fabrics.size.should eq(1)
        cluster.nocs.size.should eq(1)

        # Verify fabric details
        fabric = cluster.fabrics[0]
        fabric.fabric_id.should eq(0x0011223344556677_u64)
        fabric.node_id.should eq(0x1234567890ABCDEF_u64)
        fabric.vendor_id.should eq(0xFFF1_u16)
      end

      it "rejects AddNOC without CSR" do
        cluster = build_op_creds_cluster

        cluster.request_session_id = 12345_u64
        cluster.failsafe_armed = true

        # Add trusted root first
        authority = TestCertificateAuthority.default
        root_cert = authority.root_certificate
        add_root_tlv = create_add_trusted_root_cert_request_tlv(root_cert)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          add_root_tlv
        )

        # Try to add NOC without CSR
        noc_bytes = create_mock_noc(0x1234567890ABCDEF_u64, 0x0011223344556677_u64)

        ipk = Bytes.new(16, 0x02_u8)
        add_noc_tlv = create_add_noc_request_tlv(noc_bytes, nil, ipk, 0xABCD_u64, 0xFFF1_u16)

        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          add_noc_tlv
        )

        # Should return error response (MissingCsr)
        result.should be_a(Matter::Cluster::CommandResponse)
        # Parse response and check status
        parsed = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
        response = parsed.value.as(TLV::Structure)
        status = response[0_u8].value.as(Int)
        status.should eq(4) # MissingCsr
      end

      it "rejects AddNOC without trusted root" do
        cluster = build_op_creds_cluster

        cluster.request_session_id = 12345_u64
        cluster.failsafe_armed = true

        # Generate CSR
        nonce = Bytes.new(32, 0x42_u8)
        csr_request_tlv = create_csr_request_tlv(nonce, false)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          csr_request_tlv
        )

        # Try to add NOC without trusted root
        noc_bytes = create_mock_noc_with_key(0x1234567890ABCDEF_u64, 0x0011223344556677_u64, csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)))

        ipk = Bytes.new(16, 0x02_u8)
        add_noc_tlv = create_add_noc_request_tlv(noc_bytes, nil, ipk, 0xABCD_u64, 0xFFF1_u16)

        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          add_noc_tlv
        )

        # Should return error response (InvalidNoc - root cert not set)
        result.should be_a(Matter::Cluster::CommandResponse)
        parsed = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
        response = parsed.value.as(TLV::Structure)
        status = response[0_u8].value.as(Int)
        status.should eq(3) # InvalidNoc
      end
    end

    describe "NOC update flow" do
      it "completes CSR(update) → UpdateNOC flow" do
        cluster = build_op_creds_cluster

        # First, add a fabric using the commissioning flow
        cluster.request_session_id = 12345_u64
        cluster.failsafe_armed = true

        # Initial commissioning
        nonce = Bytes.new(32, 0x42_u8)
        csr_request_tlv = create_csr_request_tlv(nonce, false)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          csr_request_tlv
        )

        authority = TestCertificateAuthority.default
        root_cert = authority.root_certificate
        add_root_tlv = create_add_trusted_root_cert_request_tlv(root_cert)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          add_root_tlv
        )

        original_noc = create_mock_noc_with_key(0x1234567890ABCDEF_u64, 0x0011223344556677_u64, csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)))

        ipk = Bytes.new(16, 0x02_u8)
        add_noc_tlv = create_add_noc_request_tlv(original_noc, nil, ipk, 0xABCD_u64, 0xFFF1_u16)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          add_noc_tlv
        )

        initial_fabric_index = cluster.fabrics[0].fabric_index

        # Reset failsafe context to simulate new failsafe period
        cluster.on_failsafe_expired
        cluster.failsafe_armed = true
        cluster.request_session_id = 54321_u64
        cluster.request_fabric_index = initial_fabric_index

        # Now update the NOC
        # Step 1: Generate CSR for update
        update_nonce = Bytes.new(32, 0x99_u8)
        update_csr_request_tlv = create_csr_request_tlv(update_nonce, true) # is_for_update = true
        # An UpdateNOC CSR is only valid on the CASE session of the fabric it updates
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          update_csr_request_tlv,
          session_id: 54321_u64,
          is_case_session: true,
          fabric_index: initial_fabric_index
        )

        # Step 2: Update NOC with new certificate (same fabric_id)
        new_noc = create_mock_noc_with_key(0xFEDCBA0987654321_u64, 0x0011223344556677_u64, csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)))

        update_noc_tlv = create_update_noc_request_tlv(new_noc, nil, initial_fabric_index)
        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_UPDATE_NOC,
          update_noc_tlv,
          session_id: 54321_u64,
          fabric_index: initial_fabric_index
        )

        result.should be_a(Matter::Cluster::CommandResponse)

        # Parse response to check status
        parsed = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
        response = parsed.value.as(TLV::Structure)
        status = response[0_u8].value.as(Int)
        status.should eq(0) # Success

        # Verify fabric was updated, not added
        cluster.commissioned_fabrics.should eq(1_u8)

        # Verify node_id changed
        fabric = cluster.fabrics[0]
        fabric.node_id.should eq(0xFEDCBA0987654321_u64)
        fabric.fabric_id.should eq(0x0011223344556677_u64) # Same fabric_id
      end

      it "rejects UpdateNOC with AddTrustedRoot in failsafe" do
        cluster = build_op_creds_cluster

        # First, add an initial fabric via full commissioning flow
        cluster.request_session_id = 1_u64
        cluster.failsafe_armed = true

        # Initial commissioning
        nonce1 = Bytes.new(32, 0x11_u8)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          create_csr_request_tlv(nonce1, false)
        )

        authority1 = TestCertificateAuthority.default
        root_cert1 = authority1.root_certificate(0xAAAAAAAAAAAAAAAA_u64)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          create_add_trusted_root_cert_request_tlv(root_cert1)
        )

        noc1 = Matter::Crypto::MatterCertificate::Builder.node(
          public_key: csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)),
          fabric_id: 0xAAAAAAAAAAAAAAAA_u64,
          node_id: 0x1111111111111111_u64,
          issuer_key: authority1.key,
          issuer_rcac_id: 0xAAAAAAAAAAAAAAAA_u64,
          issuer_certificate: root_cert1,
          serial: Bytes[1])

        ipk1 = Bytes.new(16, 0x01_u8)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc1, nil, ipk1, 0xABCD_u64, 0xFFF1_u16)
        )

        fabric_index = cluster.fabrics[0].fabric_index

        # Reset failsafe for update attempt
        cluster.on_failsafe_expired
        cluster.request_session_id = 12345_u64
        cluster.request_fabric_index = fabric_index
        cluster.failsafe_armed = true

        # Generate CSR for update, on the CASE session of the fabric it updates
        nonce = Bytes.new(32, 0x42_u8)
        csr_request_tlv = create_csr_request_tlv(nonce, true)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          csr_request_tlv,
          session_id: 12345_u64,
          is_case_session: true,
          fabric_index: fabric_index
        )

        # Try to add trusted root (not allowed for updates)
        authority = TestCertificateAuthority.default
        root_cert = authority.root_certificate
        add_root_tlv = create_add_trusted_root_cert_request_tlv(root_cert)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          add_root_tlv
        )

        # Try UpdateNOC - should fail because root cert was set
        noc_bytes = create_mock_noc(0x2222222222222222_u64, 0xAAAAAAAAAAAAAAAA_u64)

        update_noc_tlv = create_update_noc_request_tlv(noc_bytes, nil, fabric_index)
        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_UPDATE_NOC,
          update_noc_tlv,
          session_id: 12345_u64,
          is_case_session: true,
          fabric_index: fabric_index
        )

        # Should return InvalidNoc error (root cert cannot be set for updates)
        result.should be_a(Matter::Cluster::CommandResponse)
        parsed = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
        response = parsed.value.as(TLV::Structure)
        status = response[0_u8].value.as(Int)
        status.should eq(3) # InvalidNoc
      end
    end

    describe "Fabrics attribute read after AddNOC" do
      it "returns non-empty Fabrics attribute after successful AddNOC" do
        fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
        cluster = Matter::Cluster::OperationalCredentials.new(fabric_table, endpoint(0), nil)

        # Verify fabric_table is empty initially
        fabric_table.size.should eq(0)

        # Set session context for commissioning
        cluster.request_session_id = 12345_u64
        cluster.failsafe_armed = true

        # Step 1: Generate CSR
        nonce = Bytes.new(32, 0x42_u8)
        csr_request_tlv = create_csr_request_tlv(nonce, false)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          csr_request_tlv
        )

        # Step 2: Add trusted root certificate
        authority = TestCertificateAuthority.default

        root_cert = authority.root_certificate
        add_root_tlv = create_add_trusted_root_cert_request_tlv(root_cert)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          add_root_tlv
        )

        # Step 3: Create and add NOC
        noc_bytes = create_mock_noc_with_key(0x1234567890ABCDEF_u64, 0x0011223344556677_u64, csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)))

        ipk = Bytes.new(16, 0x02_u8)
        add_noc_tlv = create_add_noc_request_tlv(
          noc_bytes,
          nil,
          ipk,
          0xABCDEF0123456789_u64,
          0xFFF1_u16
        )
        noc_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          add_noc_tlv
        )

        # Verify AddNOC succeeded
        noc_result.should be_a(Matter::Cluster::CommandResponse)
        parsed = noc_result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
        response = parsed.value.as(TLV::Structure)
        status = response[0_u8].value.as(Int)
        status.should eq(0) # Success

        # Verify fabric was added to fabric_table
        fabric_table.size.should eq(1)

        # Verify cluster.fabrics returns the fabric
        cluster.fabrics.size.should eq(1)

        # NOW TEST THE ACTUAL ISSUE: Read the Fabrics attribute
        # This is what the iPhone does after commissioning
        read_tlv(cluster, Matter::Cluster::OperationalCredentials::ATTR_FABRICS).as_list.size.should eq(1)
      end
    end
  end
end
