require "../spec_helper"

private alias StatusReport = Matter::Session::Pase::Definitions::StatusReport

describe "named protocol identifier mappings" do
  it "maps reserved endpoint, group, session, and fabric identifiers" do
    Matter::DataType::EndpointNumber::ROOT.number.should eq(0_u16)
    Matter::DataType::GroupId::RESERVED.id.should eq(0_u16)
    Matter::DataType::NO_FABRIC.should eq(0_u8)
    Matter::Fabric::RESERVED_FABRIC_ID.should eq(0_u64)
    Matter::DataType::NodeId::UNSPECIFIED.should eq(0_u64)
    Matter::Codec::MessageCodec::UNSECURED_SESSION_ID.should eq(0_u16)
    Matter::Session::UnsecuredContext::UNSPECIFIED_INITIATOR_SESSION_ID.should eq(0_u16)
  end

  it "maps PASE, IPK, and Secure Channel status identifiers" do
    Matter::Session::Pase::Definitions::PbkdfParamRequest::DEFAULT_PASSCODE_ID.should eq(0_u16)
    Matter::Cluster::GroupKeyManagement::IPK_KEY_SET_ID.should eq(0_u16)
    Matter::Cluster::CameraAvStreamManagement::MIN_STREAM_ID.should eq(0_u16)
    Matter::Cluster::TlsCertificateManagement::MIN_CERTIFICATE_ID.should eq(0_u16)
    StatusReport::SECURE_CHANNEL_PROTOCOL_ID.should eq(0_u16)
    StatusReport::GENERAL_STATUS_SUCCESS.should eq(0_u16)
    StatusReport::GENERAL_STATUS_FAILURE.should eq(1_u16)
    StatusReport::CASE_NO_SHARED_ROOT.should eq(1_u16)
  end
end
