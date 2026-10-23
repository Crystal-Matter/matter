require "../spec_helper"

private alias Control = Matter::Cluster::ContentControl
private alias IMCode = Matter::InteractionModel::StatusCode

describe Control do
  it "exposes the mandatory revision-one controls and persists their state" do
    cluster = build(Control)
    cluster.cluster_id.id.should eq(0x050F_u32)
    cluster.cluster_revision.should eq(1_u16)
    accepted_command_ids(cluster).should eq([Control::CMD_ENABLE, Control::CMD_DISABLE])
    [Control::CMD_ENABLE, Control::CMD_DISABLE].each do |id|
      metadata = cluster.get_command_metadata(id).as(Matter::Cluster::CommandMetadata)
      metadata.access.should eq(Matter::InteractionModel::EntryPrivilege::Manage)
      metadata.timed?.should be_true
    end
    attribute_ids(cluster).should contain(Control::ATTR_ENABLED)
    read(cluster, Control::ATTR_ENABLED).should be_false

    expect_success(invoke(cluster, Control::CMD_ENABLE))
    read(cluster, Control::ATTR_ENABLED).should be_true
    saved = cluster.save_state
    restored = build(Control)
    restored.restore_state(saved)
    read(restored, Control::ATTR_ENABLED).should be_true
    expect_success(invoke(restored, Control::CMD_DISABLE))
    read(restored, Control::ATTR_ENABLED).should be_false
  end

  it "only advertises and mutates configured optional features" do
    cluster = build(Control, feature_map: Control::Feature::BlockUnrated)
    attribute_ids(cluster).should contain(Control::ATTR_BLOCK_UNRATED)
    accepted_command_ids(cluster).should contain(Control::CMD_BLOCK_UNRATED_CONTENT)
    accepted_command_ids(cluster).should contain(Control::CMD_UNBLOCK_UNRATED_CONTENT)
    read(cluster, Control::ATTR_BLOCK_UNRATED).should be_false
    expect_success(invoke(cluster, Control::CMD_BLOCK_UNRATED_CONTENT))
    read(cluster, Control::ATTR_BLOCK_UNRATED).should be_true
    expect_success(invoke(cluster, Control::CMD_UNBLOCK_UNRATED_CONTENT))
    read(cluster, Control::ATTR_BLOCK_UNRATED).should be_false

    bare = build(Control)
    expect_status(invoke(bare, Control::CMD_BLOCK_UNRATED_CONTENT), IMCode::UnsupportedCommand)
    read_status(bare, Control::ATTR_BLOCK_UNRATED).status.should eq(IMCode::UnsupportedAttribute)
  end

  it "uses the configured ratings and rejects unknown thresholds" do
    ratings = [Control::RatingName.new("G"), Control::RatingName.new("PG"), Control::RatingName.new("R")]
    cluster = build(Control, feature_map: Control::Feature::OnDemandContentRating,
      on_demand_ratings: ratings, on_demand_rating_threshold: "R")
    attribute_ids(cluster).should contain(Control::ATTR_ON_DEMAND_RATINGS)
    accepted_command_ids(cluster).should contain(Control::CMD_SET_ON_DEMAND_RATING_THRESHOLD)
    expect_status(invoke(cluster, Control::CMD_SET_ON_DEMAND_RATING_THRESHOLD,
      Control::SetRatingRequest.new("X")), IMCode::Failure).cluster_status.should eq(0x03_u8)
    expect_success(invoke(cluster, Control::CMD_SET_ON_DEMAND_RATING_THRESHOLD,
      Control::SetRatingRequest.new("PG")))
    read(cluster, Control::ATTR_ON_DEMAND_RATING_THRESHOLD).should eq("PG")
    ratings << Control::RatingName.new("X")
    read_tlv(cluster, Control::ATTR_ON_DEMAND_RATINGS).as_list.size.should eq(3)
  end

  it "adds and removes identified applications without partial mutation" do
    app = Control::AppInfo.new(0xFFF1_u16, "radio")
    absent = Control::AppInfo.new(0xFFF1_u16, "video")
    cluster = build(Control, feature_map: Control::Feature::BlockApplications)
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app])))
    expect_status(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app])), IMCode::Failure).cluster_status.should eq(0x08_u8)
    expect_status(invoke(cluster, Control::CMD_REMOVE_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app, absent])), IMCode::Failure).cluster_status.should eq(0x09_u8)
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([] of Control::AppInfo)))
    expect_success(invoke(cluster, Control::CMD_REMOVE_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([] of Control::AppInfo)))
    read_tlv(cluster, Control::ATTR_BLOCK_APPLICATION_LIST).as_list.size.should eq(1)
    expect_success(invoke(cluster, Control::CMD_REMOVE_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app])))
    read_tlv(cluster, Control::ATTR_BLOCK_APPLICATION_LIST).as_list.should be_empty
  end

  it "assigns unique channel indexes and atomically rejects absent indexes" do
    cluster = build(Control, feature_map: Control::Feature::BlockChannels)
    cluster.on_validate_channel { |channel| channel.major_number > 0 }
    first = Control::BlockChannel.new(nil, 12_u16, 1_u16, "news")
    second = Control::BlockChannel.new(nil, 13_u16, 2_u16, "sport")
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_CHANNELS,
      Control::ChannelsRequest.new([first, second])))
    channels = read_tlv(cluster, Control::ATTR_BLOCK_CHANNEL_LIST).as_list.map { |value| Control::BlockChannel.from_tlv(value) }
    channels.map(&.block_channel_index).should eq([0_u16, 1_u16])
    expect_status(invoke(cluster, Control::CMD_REMOVE_BLOCK_CHANNELS,
      Control::ChannelIndexesRequest.new([0_u16, 9_u16])), IMCode::Failure).cluster_status.should eq(0x06_u8)
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_CHANNELS,
      Control::ChannelsRequest.new([] of Control::BlockChannel)))
    expect_success(invoke(cluster, Control::CMD_REMOVE_BLOCK_CHANNELS,
      Control::ChannelIndexesRequest.new([] of UInt16)))
    read_tlv(cluster, Control::ATTR_BLOCK_CHANNEL_LIST).as_list.size.should eq(2)
    expect_success(invoke(cluster, Control::CMD_REMOVE_BLOCK_CHANNELS,
      Control::ChannelIndexesRequest.new([0_u16])))
    read_tlv(cluster, Control::ATTR_BLOCK_CHANNEL_LIST).as_list.size.should eq(1)
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    cluster.playback_allowed?(rating: "G", channel: second).should be_false
    cluster.playback_allowed?(rating: "G", channel: first).should be_true
  end

  it "keeps scheduled rating decisions separate from on-demand ratings" do
    ratings = [Control::RatingName.new("U"), Control::RatingName.new("12"), Control::RatingName.new("18")]
    cluster = build(Control, feature_map: Control::Feature::ScheduledContentRating,
      scheduled_content_ratings: ratings, scheduled_content_rating_threshold: "18")
    expect_status(invoke(cluster, Control::CMD_SET_SCHEDULED_CONTENT_RATING_THRESHOLD,
      Control::SetRatingRequest.new("X")), IMCode::Failure).cluster_status.should eq(0x03_u8)
    expect_success(invoke(cluster, Control::CMD_SET_SCHEDULED_CONTENT_RATING_THRESHOLD,
      Control::SetRatingRequest.new("12")))
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    cluster.playback_allowed?(rating: "U", scheduled: true).should be_true
    cluster.playback_allowed?(rating: "12", scheduled: true).should be_false
    cluster.playback_allowed?(rating: "12", scheduled: false).should be_true
  end

  it "lets the host enforce the configured playback policy" do
    ratings = [Control::RatingName.new("G"), Control::RatingName.new("PG"), Control::RatingName.new("R")]
    cluster = build(Control, feature_map: Control::Feature::OnDemandContentRating |
                                          Control::Feature::BlockUnrated | Control::Feature::BlockApplications,
      on_demand_ratings: ratings, on_demand_rating_threshold: "R")
    app = Control::AppInfo.new(0xFFF1_u16, "radio")
    expect_success(invoke(cluster, Control::CMD_SET_ON_DEMAND_RATING_THRESHOLD,
      Control::SetRatingRequest.new("PG")))
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app])))
    expect_success(invoke(cluster, Control::CMD_BLOCK_UNRATED_CONTENT))
    cluster.playback_allowed?(rating: "R", application: app).should be_true
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    cluster.playback_allowed?(rating: "G").should be_true
    cluster.playback_allowed?(rating: "PG").should be_false
    cluster.playback_allowed?(rating: "R").should be_false
    cluster.playback_allowed?(rating: nil).should be_false
    cluster.playback_allowed?(rating: "G", application: app).should be_false
  end

  it "rejects optional feature bits whose behavior is not implemented yet" do
    expect_raises(ArgumentError) { build(Control, feature_map: Control::Feature::ScreenTime) }
    expect_raises(ArgumentError) { build(Control, feature_map: Control::Feature::PinManagement) }
    expect_raises(ArgumentError) { build(Control, feature_map: Control::Feature::BlockContentTimeWindow) }
    expect_raises(ArgumentError) do
      build(Control, feature_map: Control::Feature::OnDemandContentRating,
        on_demand_ratings: [Control::RatingName.new("G")])
    end
    expect_raises(ArgumentError) do
      build(Control, block_application_list: [Control::AppInfo.new(0xFFF1_u16, "radio")])
    end
  end

  it "notifies a media host of policy changes and restores configured lists" do
    app = Control::AppInfo.new(0xFFF1_u16, "radio")
    cluster = build(Control, feature_map: Control::Feature::BlockApplications | Control::Feature::BlockUnrated)
    calls = 0
    cluster.on_policy_changed { calls += 1 }
    cluster.on_identify_application { |candidate| candidate.application_id == "radio" }
    expect_status(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([Control::AppInfo.new(0xFFF1_u16, "unknown")])),
      IMCode::Failure).cluster_status.should eq(0x07_u8)
    calls.should eq(0)
    expect_success(invoke(cluster, Control::CMD_ADD_BLOCK_APPLICATIONS,
      Control::ApplicationsRequest.new([app])))
    expect_success(invoke(cluster, Control::CMD_BLOCK_UNRATED_CONTENT))
    expect_success(invoke(cluster, Control::CMD_ENABLE))
    calls.should eq(3)
    cluster.playback_allowed?(rating: "PG").should be_true
    cluster.playback_allowed?(rating: nil).should be_false

    restored = build(Control, feature_map: Control::Feature::BlockApplications | Control::Feature::BlockUnrated)
    restored.restore_state(cluster.save_state)
    read_tlv(restored, Control::ATTR_BLOCK_APPLICATION_LIST).as_list.size.should eq(1)
    restored.playback_allowed?(application: app, rating: "PG").should be_false
  end
end
