require "../support/operational_credentials_helpers"

describe Matter::Cluster::OperationalCredentials do
  describe "fabric management" do
    it "tracks fabric list" do
      cluster = build_op_creds_cluster

      cluster.fabrics.should be_empty
      cluster.commissioned_fabrics.should eq(0_u8)
    end

    it "finds fabric by index" do
      cluster = build_op_creds_cluster

      fabric = cluster.get_fabric_by_index(1_u8)
      fabric.should be_nil
    end

    it "checks fabric count against limit" do
      cluster = build_op_creds_cluster

      cluster.has_fabric_capacity?.should be_true
    end
  end

  describe "current fabric" do
    it "reports the accessing fabric, none outside a fabric" do
      cluster = build_op_creds_cluster

      cluster.current_fabric_index.should eq(Matter::DataType::NO_FABRIC)
      read(cluster, Matter::Cluster::OperationalCredentials::ATTR_CURRENT_FABRIC_INDEX, 1_u8).should eq(1_u8)
    end
  end

  describe "fabric table accessors" do
    it "creates cluster with existing fabrics" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      fabric = OpCredsTestHelpers.create_test_fabric(0x123_u64, 1_u8)
      fabric_table.add_fabric(fabric)

      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      cluster.commissioned_fabrics.should eq(1)
      cluster.fabrics.size.should eq(1)
    end

    it "returns empty NOCs for non-existent fabric" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      cluster.get_noc_by_fabric_index(99_u8).should be_nil
    end

    it "returns current fabric index from session" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      cluster.current_fabric_index(5_u8).should eq(5_u8)
      cluster.current_fabric_index(nil).should eq(0_u8)
    end
  end

  describe "UpdateFabricLabel command" do
    it "validates label length" do
      expect_raises(ArgumentError, "label must be <= 32 characters") do
        Matter::Cluster::OperationalCredentials::UpdateFabricLabelCommand.new(
          label: "A" * 33 # Too long
        )
      end
    end

    it "rejects update for non-existent fabric" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      cmd = Matter::Cluster::OperationalCredentials::UpdateFabricLabelCommand.new(
        label: "NewLabel"
      )

      response = cluster.handle_update_fabric_label(cmd, session_fabric_index: 99_u8)
      response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidFabricIndex)
    end
  end

  describe "RemoveFabric command" do
    it "removes fabric-scoped ACL entries when fabric is removed" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      acl_cluster = build(Matter::Cluster::AccessControl, 0)
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table, acl_cluster)

      # Add a fabric
      fabric = OpCredsTestHelpers.create_test_fabric(0x123_u64, 1_u8)
      fabric_table.add_fabric(fabric)

      # Manually add ACL entries for this fabric
      acl_entry1 = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Administer,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x1111_u64],
        targets: nil,
        fabric_index: 1_u8
      )
      acl_cluster.acl << acl_entry1

      # Add ACL entry for a different fabric
      acl_entry2 = Matter::Cluster::AccessControl::AccessControlEntry.new(
        privilege: Matter::Cluster::AccessControl::AccessControlEntryPrivilege::Manage,
        auth_mode: Matter::Cluster::AccessControl::AccessControlEntryAuthMode::CASE,
        subjects: [0x2222_u64],
        targets: nil,
        fabric_index: 2_u8
      )
      acl_cluster.acl << acl_entry2

      # Verify ACL state before removal
      acl_cluster.acl.size.should eq(2)

      # Remove fabric 1
      cmd = Matter::Cluster::OperationalCredentials::RemoveFabricCommand.new(
        fabric_index: 1_u8
      )
      response = cluster.handle_remove_fabric(cmd)
      response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::Ok)

      # Verify only fabric 1's ACL entry was removed
      acl_cluster.acl.size.should eq(1)
      acl_cluster.acl.first.fabric_index.should eq(2_u8)
      acl_cluster.acl.first.subjects.should eq([0x2222_u64])
    end

    it "rejects removal of non-existent fabric" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      fabric_table.add_fabric(OpCredsTestHelpers.create_test_fabric(1_u64, 1_u8))
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      cmd = Matter::Cluster::OperationalCredentials::RemoveFabricCommand.new(
        fabric_index: 99_u8
      )

      response = cluster.handle_remove_fabric(cmd)
      response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::InvalidFabricIndex)
    end

    it "treats removal as idempotent while the device has no fabrics" do
      # iOS removes a stale fabric while re-commissioning a device that has
      # already been factory reset; the commissioner has to be able to move on.
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      cmd = Matter::Cluster::OperationalCredentials::RemoveFabricCommand.new(
        fabric_index: 99_u8
      )

      response = cluster.handle_remove_fabric(cmd)
      response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::Ok)
    end
  end

  describe "failsafe management" do
    it "resets context on failsafe expired" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      # Set up attestation credentials
      dac = Bytes.new(100, 1_u8)
      pai = Bytes.new(100, 2_u8)
      key = Matter::Crypto::Key.generate_key_pair
      cluster.set_attestation_credentials(dac, pai, key)

      # CSR to set context
      csr_cmd = Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(
        csr_nonce: Bytes.new(32, 0_u8)
      )
      cluster.handle_csr_request(csr_cmd, session_id: 1_u64, is_pase_session: true, failsafe_armed: true)

      # Simulate failsafe expiry
      cluster.on_failsafe_expired

      # Try to add NOC - should fail due to missing CSR
      cmd = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
        noc_value: Bytes.new(100),
        icac_value: nil,
        ipk_value: Bytes.new(16),
        case_admin_subject: 1_u64,
        admin_vendor_id: 0xFFF1_u16
      )

      response = cluster.handle_add_noc(cmd, session_id: 1_u64, failsafe_armed: true)
      response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::MissingCsr)
    end

    it "resets context on failsafe success" do
      fabric_table = OpCredsTestHelpers.create_fabric_table
      cluster = Matter::Cluster::OperationalCredentials.new(fabric_table)

      # Set up attestation credentials
      dac = Bytes.new(100, 1_u8)
      pai = Bytes.new(100, 2_u8)
      key = Matter::Crypto::Key.generate_key_pair
      cluster.set_attestation_credentials(dac, pai, key)

      # CSR to set context
      csr_cmd = Matter::Cluster::OperationalCredentials::CSRRequestCommand.new(
        csr_nonce: Bytes.new(32, 0_u8)
      )
      cluster.handle_csr_request(csr_cmd, session_id: 1_u64, is_pase_session: true, failsafe_armed: true)

      # Simulate failsafe success
      cluster.on_failsafe_success

      # Context should be reset
      cmd = Matter::Cluster::OperationalCredentials::AddNOCCommand.new(
        noc_value: Bytes.new(100),
        icac_value: nil,
        ipk_value: Bytes.new(16),
        case_admin_subject: 1_u64,
        admin_vendor_id: 0xFFF1_u16
      )

      response = cluster.handle_add_noc(cmd, session_id: 1_u64, failsafe_armed: true)
      response.status_code.should eq(Matter::Cluster::OperationalCredentials::NodeOperationalCertStatus::MissingCsr)
    end
  end

  describe "integration tests" do
    describe "failsafe constraints" do
      it "prevents calling CSR after AddNOC in same failsafe" do
        cluster = build_op_creds_cluster

        cluster.request_session_id = 12345_u64
        cluster.failsafe_armed = true

        # Complete full commissioning
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

        noc_bytes = create_mock_noc_with_key(0x1234567890ABCDEF_u64, 0x0011223344556677_u64, csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)))

        ipk = Bytes.new(16, 0x02_u8)
        add_noc_tlv = create_add_noc_request_tlv(noc_bytes, nil, ipk, 0xABCD_u64, 0xFFF1_u16)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          add_noc_tlv
        )

        # Try to call CSR again in same failsafe - should fail
        new_nonce = Bytes.new(32, 0x99_u8)
        new_csr_request_tlv = create_csr_request_tlv(new_nonce, false)
        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          new_csr_request_tlv
        )

        # CSRRequest cannot return an error payload. If it fails, it must return an
        # IM StatusIB in the InvokeResponse (as opposed to a CSRResponse payload).
        result.should be_a(Matter::InteractionModel::Status)
        status = result.as(Matter::InteractionModel::Status)
        status.status.should eq(Matter::InteractionModel::StatusCode::Failure)
        status.cluster_status.should eq(4_u8) # NodeOperationalCertStatus::MissingCsr
      end

      it "allows CSR after failsafe expiry" do
        cluster = build_op_creds_cluster

        cluster.request_session_id = 12345_u64
        cluster.failsafe_armed = true

        # Generate initial CSR
        nonce = Bytes.new(32, 0x42_u8)
        csr_request_tlv = create_csr_request_tlv(nonce, false)
        result1 = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          csr_request_tlv
        )
        result1.should be_a(Matter::Cluster::CommandResponse)

        # Expire failsafe
        cluster.on_failsafe_expired
        cluster.failsafe_armed = true
        cluster.request_session_id = 54321_u64

        # Generate new CSR - should succeed
        new_nonce = Bytes.new(32, 0x99_u8)
        new_csr_request_tlv = create_csr_request_tlv(new_nonce, false)
        result2 = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          new_csr_request_tlv
        )

        result2.should be_a(Matter::Cluster::CommandResponse)
        result2.as(Matter::Cluster::CommandResponse).response.as(TLV::Any).to_slice.size.should be > 20 # Valid CSR response
      end
    end

    describe "multi-fabric scenarios" do
      it "adds multiple fabrics" do
        cluster = build_op_creds_cluster

        # Add first fabric
        cluster.request_session_id = 1_u64
        cluster.failsafe_armed = true

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

        noc1 = create_mock_noc_with_key(0x1111111111111111_u64, 0xAAAAAAAAAAAAAAAA_u64,
          csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)), 0xAAAAAAAAAAAAAAAA_u64)

        ipk1 = Bytes.new(16, 0x01_u8)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc1, nil, ipk1, 0xABCD_u64, 0xFFF1_u16)
        )

        # Reset failsafe for second fabric
        cluster.on_failsafe_success
        cluster.request_session_id = 2_u64
        cluster.failsafe_armed = true

        # Add second fabric
        nonce2 = Bytes.new(32, 0x22_u8)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          create_csr_request_tlv(nonce2, false)
        )

        authority2 = TestCertificateAuthority.new
        root_cert2 = authority2.root_certificate(0xBBBBBBBBBBBBBBBB_u64)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          create_add_trusted_root_cert_request_tlv(root_cert2)
        )

        noc2 = authority2.issue(0xBBBBBBBBBBBBBBBB_u64, 0x2222222222222222_u64,
          csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)), 0xBBBBBBBBBBBBBBBB_u64)

        ipk2 = Bytes.new(16, 0x02_u8)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc2, nil, ipk2, 0xDEF0_u64, 0xFFF2_u16)
        )

        # Verify both fabrics exist
        cluster.commissioned_fabrics.should eq(2_u8)
        cluster.fabrics.size.should eq(2)

        fabric1 = cluster.fabrics.find { |fabric| fabric.fabric_id == 0xAAAAAAAAAAAAAAAA_u64 }
        fabric2 = cluster.fabrics.find { |fabric| fabric.fabric_id == 0xBBBBBBBBBBBBBBBB_u64 }

        fabric1.should_not be_nil
        fabric2.should_not be_nil
      end

      it "allows duplicate fabric_id across different roots" do
        cluster = build_op_creds_cluster

        # Add first fabric
        cluster.request_session_id = 1_u64
        cluster.failsafe_armed = true

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

        same_fabric_id = 0xAAAAAAAAAAAAAAAA_u64

        noc1 = create_mock_noc_with_key(0x1111111111111111_u64, same_fabric_id,
          csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)), 0xAAAAAAAAAAAAAAAA_u64)

        ipk1 = Bytes.new(16, 0x01_u8)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc1, nil, ipk1, 0xABCD_u64, 0xFFF1_u16)
        )

        # Reset and try to add fabric with same fabric_id
        cluster.on_failsafe_success
        cluster.request_session_id = 2_u64
        cluster.failsafe_armed = true

        nonce2 = Bytes.new(32, 0x22_u8)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          create_csr_request_tlv(nonce2, false)
        )

        authority2 = TestCertificateAuthority.new
        root_cert2 = authority2.root_certificate(0xBBBBBBBBBBBBBBBB_u64)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          create_add_trusted_root_cert_request_tlv(root_cert2)
        )

        noc2 = authority2.issue(same_fabric_id, 0x2222222222222222_u64,
          csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)), 0xBBBBBBBBBBBBBBBB_u64)

        ipk2 = Bytes.new(16, 0x02_u8)
        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc2, nil, ipk2, 0xDEF0_u64, 0xFFF2_u16)
        )

        # Should succeed because (root_public_key, fabric_id) is unique.
        result.should be_a(Matter::Cluster::CommandResponse)
        parsed = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
        response = parsed.value.as(TLV::Structure)
        status = response[0_u8].value.as(Int)
        status.should eq(0_u8) # Success
        cluster.fabrics.size.should eq(2)
      end

      it "prevents duplicate fabric identity (same root + fabric_id)" do
        cluster = build_op_creds_cluster

        # Add first fabric
        cluster.request_session_id = 1_u64
        cluster.failsafe_armed = true

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

        same_fabric_id = 0xAAAAAAAAAAAAAAAA_u64
        noc1 = create_mock_noc_with_key(0x1111111111111111_u64, same_fabric_id,
          csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)), 0xAAAAAAAAAAAAAAAA_u64)

        ipk1 = Bytes.new(16, 0x01_u8)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc1, nil, ipk1, 0xABCD_u64, 0xFFF1_u16)
        )

        # Reset and try to add a fabric with same fabric_id AND same root
        cluster.on_failsafe_success
        cluster.request_session_id = 2_u64
        cluster.failsafe_armed = true

        nonce2 = Bytes.new(32, 0x22_u8)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          create_csr_request_tlv(nonce2, false)
        )

        # Re-use the same root cert.
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          create_add_trusted_root_cert_request_tlv(root_cert1)
        )

        noc2 = authority1.issue(same_fabric_id, 0x2222222222222222_u64)
        ipk2 = Bytes.new(16, 0x02_u8)
        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc2, nil, ipk2, 0xDEF0_u64, 0xFFF2_u16)
        )

        # Should return FabricConflict error
        result.should be_a(Matter::Cluster::CommandResponse)
        parsed = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
        response = parsed.value.as(TLV::Structure)
        status = response[0_u8].value.as(Int)
        status.should eq(9_u8) # FabricConflict
      end
    end

    describe "fabric label management" do
      it "updates fabric label" do
        fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
        cluster = Matter::Cluster::OperationalCredentials.new(fabric_table, endpoint(0), nil)

        # Add a fabric
        cluster.request_session_id = 1_u64
        cluster.failsafe_armed = true

        nonce = Bytes.new(32, 0x42_u8)
        csr_result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
          create_csr_request_tlv(nonce, false)
        )

        authority = TestCertificateAuthority.default
        root_cert = authority.root_certificate
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
          create_add_trusted_root_cert_request_tlv(root_cert)
        )

        noc = create_mock_noc_with_key(0x1234567890ABCDEF_u64, 0x0011223344556677_u64, csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)))

        ipk = Bytes.new(16, 0x02_u8)
        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
          create_add_noc_request_tlv(noc, nil, ipk, 0xABCD_u64, 0xFFF1_u16)
        )

        fabric_index = cluster.fabrics[0].fabric_index
        cluster.request_fabric_index = fabric_index

        # Update label
        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_UPDATE_FABRIC_LABEL,
          create_update_fabric_label_request("MyFabricLabel", fabric_index)
        )

        result.should be_a(Matter::Cluster::CommandResponse)

        # Verify label was updated
        fabric = cluster.fabrics[0]
        fabric.label.should eq("MyFabricLabel")
      end

      it "rejects duplicate fabric labels" do
        fabric_table = Matter::FabricTable.new(Matter::Storage::Memory.new)
        cluster = Matter::Cluster::OperationalCredentials.new(fabric_table, endpoint(0), nil)

        # Add two fabrics
        2.times do |i|
          cluster.on_failsafe_success if i > 0
          cluster.request_session_id = (i + 1).to_u64
          cluster.failsafe_armed = true

          nonce = Bytes.new(32, i.to_u8)
          csr_result = invoke(cluster,
            Matter::Cluster::OperationalCredentials::CMD_CSR_REQUEST,
            create_csr_request_tlv(nonce, false)
          )

          authority = TestCertificateAuthority.default
          root_cert = authority.root_certificate
          invoke(cluster,
            Matter::Cluster::OperationalCredentials::CMD_ADD_TRUSTED_ROOT_CERTIFICATE,
            create_add_trusted_root_cert_request_tlv(root_cert)
          )

          noc = create_mock_noc_with_key(0x1111111111111111_u64 + i, 0xAAAAAAAAAAAAAAAA_u64 + i, csr_public_key(csr_result.as(Matter::Cluster::CommandResponse)))

          ipk = Bytes.new(16, i.to_u8)
          invoke(cluster,
            Matter::Cluster::OperationalCredentials::CMD_ADD_NOC,
            create_add_noc_request_tlv(noc, nil, ipk, 0xABCD_u64, 0xFFF1_u16)
          )
        end

        # Set label on first fabric
        fabric1_index = cluster.fabrics[0].fabric_index
        cluster.request_fabric_index = fabric1_index

        invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_UPDATE_FABRIC_LABEL,
          create_update_fabric_label_request("SharedLabel", fabric1_index)
        )

        # Try to set same label on second fabric
        fabric2_index = cluster.fabrics[1].fabric_index
        cluster.request_fabric_index = fabric2_index

        result = invoke(cluster,
          Matter::Cluster::OperationalCredentials::CMD_UPDATE_FABRIC_LABEL,
          create_update_fabric_label_request("SharedLabel", fabric2_index) # Same label!
        )

        # Should return LabelConflict error
        result.should be_a(Matter::Cluster::CommandResponse)
        parsed = result.as(Matter::Cluster::CommandResponse).response.as(TLV::Any)
        response = parsed.value.as(TLV::Structure)
        status = response[0_u8].value.as(Int)
        status.should eq(10_u8) # LabelConflict
      end
    end
  end
end
