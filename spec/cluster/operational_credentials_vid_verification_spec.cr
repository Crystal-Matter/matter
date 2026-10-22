require "../support/operational_credentials_helpers"

describe "OperationalCredentials SignVIDVerificationRequest" do
  it "rejects reserved AddNOC administrator Vendor IDs before entering commissioning" do
    cluster = Matter::Cluster::OperationalCredentials.new(Matter::FabricTable.new(Matter::Storage::Memory.new))
    [0_u16, 0xFFF5_u16, 0xFFFF_u16].each do |vendor_id|
      request = Matter::Cluster::OperationalCredentials::Tlv::AddNocRequest.new(
        Bytes.empty, nil, Bytes.new(16), 1_u64, vendor_id)
      cluster.add_noc(request).should eq(Matter::InteractionModel::Status.invalid_command)
    end
    request = Matter::Cluster::OperationalCredentials::Tlv::AddNocRequest.new(
      Bytes.empty, nil, Bytes.new(16), 1_u64, 0xFFF4_u16)
    cluster.add_noc(request).should be_a(Matter::Cluster::OperationalCredentials::Tlv::TlvNocResponse)
  end

  it "rejects reserved operational Vendor IDs and accepts the last test Vendor ID" do
    table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    table.add_fabric(OpCredsTestHelpers.create_test_fabric(0x1111_u64, 1_u8)).should be_true
    cluster = Matter::Cluster::OperationalCredentials.new(table)
    cluster.request_fabric_index = 1_u8

    [0_u16, 0xFFF5_u16, 0xFFFF_u16].each do |vendor_id|
      cluster.set_vid_verification_statement(
        Matter::Cluster::OperationalCredentials::Tlv::SetVIDVerificationStatementRequest.new(
          vendor_id: vendor_id)
      ).should eq(Matter::InteractionModel::Status.constraint_error)
      table.get_fabric(1_u8).as(Matter::Fabric).vendor_id.should eq(0xFFF1_u16)
    end

    cluster.set_vid_verification_statement(
      Matter::Cluster::OperationalCredentials::Tlv::SetVIDVerificationStatementRequest.new(
        vendor_id: 0xFFF4_u16)
    ).should eq(Matter::InteractionModel::Status.success)
    table.get_fabric(1_u8).as(Matter::Fabric).vendor_id.should eq(0xFFF4_u16)
  end

  it "signs the exact fabric binding and session challenges with the selected NOC key" do
    crypto = Matter::Crypto::StandardCrypto.new
    root_key = crypto.create_key_pair
    node_key = crypto.create_key_pair
    root = Matter::Crypto::MatterCertificate::Builder.root(root_key, 1_u64, Bytes[0x01], crypto)
    noc = Matter::Crypto::MatterCertificate::Builder.node(
      node_key.public_key, 0x1234_u64, 0x5678_u64, root_key, 1_u64, Bytes[0x02], crypto
    )
    table = Matter::FabricTable.new(Matter::Storage::Memory.new)
    fabric = Matter::Fabric.new(
      fabric_id: 0x1234_u64,
      fabric_index: 1_u8,
      node_id: 0x5678_u64,
      root_public_key: root_key.public_key,
      operational_cert: noc,
      operational_key: node_key,
      ipk: Bytes.new(16, 0_u8),
      vendor_id: 0xFFF1_u16,
      root_cert: root
    )
    table.add_fabric(fabric).should be_true
    cluster = Matter::Cluster::OperationalCredentials.new(table)
    challenge = Bytes.new(16, 0xA5_u8)
    cluster.session_lookup = ->(_session : UInt64) { challenge.as(Bytes?) }
    cluster.request_session_id = 4_u64
    client_challenge = Bytes.new(32, 0x5A_u8)
    request = Matter::Cluster::OperationalCredentials::Tlv::SignVIDVerificationRequest.new(1_u8, client_challenge)

    response = cluster.sign_vid_verification_request(request).as(
      Matter::Cluster::OperationalCredentials::Tlv::SignVIDVerificationResponse)
    response.fabric_index.should eq(1_u8)
    response.fabric_binding_version.should eq(1_u8)
    expected = IO::Memory.new
    expected.write_byte 1_u8
    expected.write client_challenge
    expected.write challenge
    expected.write_byte 1_u8
    expected.write_byte 1_u8
    expected.write root_key.public_key
    expected.write_bytes 0x1234_u64, IO::ByteFormat::BigEndian
    expected.write_bytes 0xFFF1_u16, IO::ByteFormat::BigEndian
    crypto.verify_ecdsa(node_key, expected.to_slice, response.signature)

    invalid = Matter::Cluster::OperationalCredentials::Tlv::SignVIDVerificationRequest.new(2_u8, client_challenge)
    cluster.sign_vid_verification_request(invalid).should eq(Matter::InteractionModel::Status.constraint_error)
  end

  it "stores, advertises and signs a VID verification statement on the accessing fabric only" do
    crypto = Matter::Crypto::StandardCrypto.new
    backing = Matter::Storage::Memory.new
    table = Matter::FabricTable.new(backing)
    first = OpCredsTestHelpers.create_test_fabric(0x1111_u64, 1_u8)
    second = OpCredsTestHelpers.create_test_fabric(0x2222_u64, 2_u8)
    table.add_fabric(first).should be_true
    table.add_fabric(second).should be_true
    cluster = Matter::Cluster::OperationalCredentials.new(table)
    cluster.request_fabric_index = 1_u8
    cluster.request_fabric_filtered = true
    cluster.fabrics.size.should eq(1)
    cluster.nocs.size.should eq(1)
    cluster.request_fabric_filtered = false
    cluster.fabrics.size.should eq(2)
    cluster.nocs.size.should eq(2)

    statement = Bytes.new(85, 0x42_u8)
    request = Matter::Cluster::OperationalCredentials::Tlv::SetVIDVerificationStatementRequest.new(
      vendor_id: 0x1234_u16, vid_verification_statement: statement
    )
    cluster.set_vid_verification_statement(request).should eq(Matter::InteractionModel::Status.success)
    cluster.fabrics.find!(&.fabric_index.==(1_u8)).vid_verification_statement.should eq(statement)
    cluster.fabrics.find!(&.fabric_index.==(2_u8)).vid_verification_statement.should be_nil
    persisted = Matter::FabricTable.new(backing).get_fabric(1_u8).as(Matter::Fabric)
    persisted.vid_verification_statement.should eq(statement)
    persisted.vendor_id.should eq(0x1234_u16)

    challenge = Bytes.new(16, 0xA5_u8)
    cluster.session_lookup = ->(_session : UInt64) { challenge.as(Bytes?) }
    cluster.request_session_id = 5_u64
    client_challenge = Bytes.new(32, 0x5A_u8)
    response = cluster.sign_vid_verification_request(
      Matter::Cluster::OperationalCredentials::Tlv::SignVIDVerificationRequest.new(1_u8, client_challenge)
    ).as(Matter::Cluster::OperationalCredentials::Tlv::SignVIDVerificationResponse)
    tbs = IO::Memory.new
    tbs.write_byte 1_u8
    tbs.write client_challenge
    tbs.write challenge
    tbs.write_byte 1_u8
    tbs.write_byte 1_u8
    tbs.write first.root_public_key
    tbs.write_bytes first.fabric_id, IO::ByteFormat::BigEndian
    tbs.write_bytes 0x1234_u16, IO::ByteFormat::BigEndian
    tbs.write statement
    crypto.verify_ecdsa(first.operational_key, tbs.to_slice, response.signature)

    cluster.set_vid_verification_statement(
      Matter::Cluster::OperationalCredentials::Tlv::SetVIDVerificationStatementRequest.new(
        vid_verification_statement: Bytes.empty
      )
    ).should eq(Matter::InteractionModel::Status.success)
    Matter::FabricTable.new(backing).get_fabric(1_u8).as(Matter::Fabric).vid_verification_statement.should be_nil
  end

  it "restores SetVID metadata after a failed NOC update's fail-safe expires" do
    backing = Matter::Storage::Memory.new
    table = Matter::FabricTable.new(backing)
    table.add_fabric(OpCredsTestHelpers.create_test_fabric(0x3333_u64, 1_u8)).should be_true
    cluster = Matter::Cluster::OperationalCredentials.new(table)
    cluster.request_fabric_index = 1_u8
    cluster.credentials.pending.noc_added_or_updated = true
    cluster.set_vid_verification_statement(
      Matter::Cluster::OperationalCredentials::Tlv::SetVIDVerificationStatementRequest.new(
        vendor_id: 0x1234_u16, vid_verification_statement: Bytes.new(85, 0x11_u8)
      )
    ).should eq(Matter::InteractionModel::Status.success)
    table.get_fabric(1_u8).as(Matter::Fabric).vendor_id.should eq(0x1234_u16)

    cluster.on_failsafe_expired
    restored = Matter::FabricTable.new(backing).get_fabric(1_u8).as(Matter::Fabric)
    restored.vendor_id.should eq(0xFFF1_u16)
    restored.vid_verification_statement.should be_nil
  end
end
