require "../spec_helper"

private alias Channel = Matter::Cluster::Channel
private alias IMCode = Matter::InteractionModel::StatusCode

describe Channel do
  it "advertises revision two and gates optional attributes and commands" do
    base = build(Channel)
    base.cluster_id.id.should eq(0x0504_u32)
    base.cluster_revision.should eq(2_u16)
    base.attributes.map(&.id.id).should eq([Channel::ATTR_CURRENT_CHANNEL])
    accepted_command_ids(base).should eq([Channel::CMD_CHANGE_CHANNEL_BY_NUMBER, Channel::CMD_SKIP_CHANNEL])

    full = build(Channel, feature_map: Channel::Feature::ChannelList |
                                       Channel::Feature::LineupInfo | Channel::Feature::ElectronicGuide | Channel::Feature::RecordProgram)
    full.feature_map.value.should eq(15_u32)
    full.attributes.map(&.id.id).should eq([Channel::ATTR_CHANNEL_LIST, Channel::ATTR_LINEUP, Channel::ATTR_CURRENT_CHANNEL])
    accepted_command_ids(full).should eq([0_u32, 2_u32, 3_u32, 4_u32, 6_u32, 7_u32])
    generated_command_ids(full).should eq([1_u32, 5_u32])
  end

  it "finds channels by number, wraps skips, and reports no match" do
    channels = [Channel::ChannelInfo.new(7_u16, 1_u16, "Seven"),
                Channel::ChannelInfo.new(9_u16, 0_u16, "Nine")]
    cluster = build(Channel, feature_map: Channel::Feature::ChannelList, channels: channels)
    cluster.on_select { |_channel| true }
    expect_status(invoke(cluster, Channel::CMD_CHANGE_CHANNEL_BY_NUMBER,
      Channel::ChangeChannelByNumberRequest.new(7_u16, 1_u16)), IMCode::Success)
    cluster.current_channel.should eq(channels.first)
    expect_status(invoke(cluster, Channel::CMD_SKIP_CHANNEL,
      Channel::SkipChannelRequest.new(-1_i16)), IMCode::Success)
    cluster.current_channel.should eq(channels.last)
    expect_status(invoke(cluster, Channel::CMD_CHANGE_CHANNEL_BY_NUMBER,
      Channel::ChangeChannelByNumberRequest.new(13_u16, 0_u16)), IMCode::NotFound)
  end

  it "does not claim a tune succeeded without a host handler" do
    channel = Channel::ChannelInfo.new(7_u16, 1_u16, "Seven")
    cluster = build(Channel, channels: [channel])
    expect_status(invoke(cluster, Channel::CMD_CHANGE_CHANNEL_BY_NUMBER,
      Channel::ChangeChannelByNumberRequest.new(7_u16, 1_u16)), IMCode::InvalidInState)
    cluster.current_channel.should be_nil
  end

  it "responds with a typed ChangeChannel status for text matches" do
    channels = [Channel::ChannelInfo.new(7_u16, 1_u16, "Seven"),
                Channel::ChannelInfo.new(8_u16, 1_u16, "Seven")]
    cluster = build(Channel, feature_map: Channel::Feature::ChannelList, channels: channels)
    cluster.on_select { |_channel| true }
    response = invoke(cluster, Channel::CMD_CHANGE_CHANNEL,
      Channel::ChangeChannelRequest.new("Seven")).as(Matter::Cluster::CommandResponse)
    response.command_id.should eq(Channel::CMD_CHANGE_CHANNEL_RESPONSE)
    Channel::ChangeChannelResponse.from_tlv(response.response.as(TLV::Any)).status.should eq(Channel::Status::MultipleMatches)
  end

  it "uses the required match priority before comparing channel names" do
    channels = [Channel::ChannelInfo.new(1_u16, 0_u16, "News", identifier: "primary"),
                Channel::ChannelInfo.new(2_u16, 0_u16, "Primary", identifier: "other")]
    cluster = build(Channel, feature_map: Channel::Feature::ChannelList, channels: channels)
    cluster.on_select { |_channel| true }
    response = invoke(cluster, Channel::CMD_CHANGE_CHANNEL,
      Channel::ChangeChannelRequest.new("PRIMARY")).as(Matter::Cluster::CommandResponse)
    Channel::ChangeChannelResponse.from_tlv(response.response.as(TLV::Any)).status.should eq(Channel::Status::Success)
    cluster.current_channel.should eq(channels.first)
  end

  it "roundtrips the guide and recording wire fields and invokes host callbacks" do
    features = Channel::Feature::ElectronicGuide | Channel::Feature::RecordProgram
    cluster = build(Channel, feature_map: features)
    guide_request = Channel::GetProgramGuideRequest.new(100_u32, 200_u32,
      page_token: Channel::PageToken.new(10_u16, after: "next"),
      recording_flag: Channel::RecordingFlag::Scheduled)
    guide_request.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 3_u8, 5_u8])
    decoded = Channel::GetProgramGuideRequest.from_tlv(guide_request.to_tlv(nil))
    decoded.page_token.try(&.after).should eq("next")
    decoded.recording_flag.should eq(Channel::RecordingFlag::Scheduled)

    expected = Channel::ProgramGuideResponse.new(Channel::ChannelPaging.new, [] of Channel::Program)
    cluster.on_program_guide { |_request| expected }
    guide = invoke(cluster, Channel::CMD_GET_PROGRAM_GUIDE, guide_request).as(Matter::Cluster::CommandResponse)
    guide.command_id.should eq(Channel::CMD_GET_PROGRAM_GUIDE_RESPONSE)
    Channel::ProgramGuideResponse.from_tlv(guide.response.as(TLV::Any)).program_list.should be_empty

    seen = [] of Bool
    cluster.on_record do |_request, cancel|
      seen << cancel
      Matter::InteractionModel::Status.success
    end
    record = Channel::RecordProgramRequest.new("p1", true)
    expect_status(invoke(cluster, Channel::CMD_RECORD_PROGRAM, record), IMCode::Success)
    expect_status(invoke(cluster, Channel::CMD_CANCEL_RECORD_PROGRAM, record), IMCode::Success)
    seen.should eq([false, true])
    expect_status(invoke(cluster, Channel::CMD_GET_PROGRAM_GUIDE,
      Channel::GetProgramGuideRequest.new(200_u32, 100_u32)), IMCode::InvalidAction)
    expect_status(invoke(cluster, Channel::CMD_RECORD_PROGRAM,
      Channel::RecordProgramRequest.new("x" * 256, false)), IMCode::ConstraintError)
  end

  it "advertises RP without EG but gates record commands, and rejects malformed payloads" do
    rp_only = build(Channel, feature_map: Channel::Feature::RecordProgram)
    rp_only.feature_map.value.should eq(8_u32)
    accepted_command_ids(rp_only).should eq([Channel::CMD_CHANGE_CHANNEL_BY_NUMBER, Channel::CMD_SKIP_CHANNEL])
    cluster = build(Channel)
    expect_status(invoke(cluster, Channel::CMD_SKIP_CHANNEL), IMCode::InvalidCommand)
    expect_status(invoke(cluster, Channel::CMD_CHANGE_CHANNEL), IMCode::UnsupportedCommand)
    expect_status(invoke(cluster, Channel::CMD_GET_PROGRAM_GUIDE), IMCode::UnsupportedCommand)
  end
end
