require "../spec_helper"

private alias ContentLauncher = Matter::Cluster::ContentLauncher
private alias IMCode = Matter::InteractionModel::StatusCode

private def launcher(features : ContentLauncher::Feature = ContentLauncher::Feature::ContentSearch | ContentLauncher::Feature::UrlPlayback) : ContentLauncher
  if features.url_playback?
    build(ContentLauncher, feature_map: features, accept_header: ["video/mp4"], supported_streaming_protocols: 3_u32)
  else
    build(ContentLauncher, feature_map: features)
  end
end

describe ContentLauncher do
  it "advertises revision two and only the feature-gated attributes and commands" do
    cluster = launcher
    cluster.cluster_id.id.should eq(0x050A_u32)
    cluster.cluster_revision.should eq(2_u16)
    cluster.attributes.map(&.id.id).should eq([ContentLauncher::ATTR_ACCEPT_HEADER, ContentLauncher::ATTR_SUPPORTED_STREAMING_PROTOCOLS])
    cluster.commands.map(&.id.id).should eq([ContentLauncher::CMD_LAUNCH_CONTENT, ContentLauncher::CMD_LAUNCH_URL])
    cluster.events.should be_empty
    read_tlv(cluster, ContentLauncher::ATTR_ACCEPT_HEADER).as_list.map(&.value.as(String)).should eq(["video/mp4"])
    read(cluster, ContentLauncher::ATTR_SUPPORTED_STREAMING_PROTOCOLS).should eq(3_u32)

    search_only = launcher(ContentLauncher::Feature::ContentSearch)
    search_only.attributes.should be_empty
    search_only.commands.map(&.id.id).should eq([ContentLauncher::CMD_LAUNCH_CONTENT])
    read_status(search_only, ContentLauncher::ATTR_ACCEPT_HEADER).status.should eq(IMCode::UnsupportedAttribute)
    url_only = launcher(ContentLauncher::Feature::UrlPlayback)
    url_only.commands.map(&.id.id).should eq([ContentLauncher::CMD_LAUNCH_URL])
  end

  it "keeps the fixed AcceptHeader isolated from caller and reader mutations" do
    headers = ["video/mp4"]
    cluster = build(ContentLauncher, feature_map: ContentLauncher::Feature::UrlPlayback,
      accept_header: headers, supported_streaming_protocols: 1_u32)
    version = cluster.data_version

    headers.clear
    cluster.accept_header.clear

    cluster.accept_header.should eq(["video/mp4"])
    read_tlv(cluster, ContentLauncher::ATTR_ACCEPT_HEADER).as_list.map(&.value.as(String)).should eq(["video/mp4"])
    cluster.data_version.should eq(version)
  end

  it "copies a host-assigned fixed AcceptHeader before retaining it" do
    cluster = build(ContentLauncher, feature_map: ContentLauncher::Feature::UrlPlayback,
      accept_header: ["video/mp4"], supported_streaming_protocols: 1_u32)
    replacement = ["video/webm"]
    cluster.accept_header = replacement
    assigned_version = cluster.data_version

    replacement.clear

    cluster.accept_header.should eq(["video/webm"])
    cluster.data_version.should eq(assigned_version)
  end

  it "restores host-configured fixed URL capabilities after restart" do
    source = build(ContentLauncher, feature_map: ContentLauncher::Feature::UrlPlayback,
      accept_header: ["video/mp4"], supported_streaming_protocols: 1_u32)
    saved = source.save_state.as(Matter::Storage::Document)
    restored = build(ContentLauncher, feature_map: ContentLauncher::Feature::UrlPlayback,
      accept_header: ["video/webm"], supported_streaming_protocols: 2_u32)

    restored.restore_state(saved)

    restored.accept_header.should eq(["video/webm"])
    restored.supported_streaming_protocols.should eq(2_u32)
    read_tlv(restored, ContentLauncher::ATTR_ACCEPT_HEADER).as_list.map(&.value.as(String)).should eq(["video/webm"])
    read(restored, ContentLauncher::ATTR_SUPPORTED_STREAMING_PROTOCOLS).should eq(2_u32)
  end

  it "encodes revision two search, preferences, URL branding and responses on canonical tags" do
    parameter = ContentLauncher::Parameter.new(ContentLauncher::ParameterType::Season, "2",
      [ContentLauncher::AdditionalInfo.new("series-id", "abc")])
    search = ContentLauncher::ContentSearch.new([parameter])
    text = ContentLauncher::TrackPreference.new("en")
    preferences = ContentLauncher::PlaybackPreferences.new(1000_u64, text, [ContentLauncher::TrackPreference.new("fr", nil, 1_u8)])
    content = ContentLauncher::LaunchContentRequest.new(search, true, "opaque", preferences, false)
    content.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8])
    decoded = ContentLauncher::LaunchContentRequest.from_tlv(content.to_tlv(nil))
    decoded.search.parameter_list.first.type.should eq(ContentLauncher::ParameterType::Season)
    decoded.search.parameter_list.first.external_id_list.try(&.first.value).should eq("abc")
    decoded.playback_preferences.try(&.audio_tracks).try(&.first?).try(&.audio_output_index).should eq(1_u8)
    ContentLauncher::LaunchContentRequest.new(search, false).to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8])
    style = ContentLauncher::StyleInformation.new("https://example.test/logo.png", "#112233",
      ContentLauncher::Dimension.new(1920.0, 1080.0, ContentLauncher::MetricType::Pixels))
    branding = ContentLauncher::BrandingInformation.new("Provider", logo: style)
    url = ContentLauncher::LaunchUrlRequest.new("https://example.test/video", "Example", branding, preferences)
    decoded_url = ContentLauncher::LaunchUrlRequest.from_tlv(url.to_tlv(nil))
    decoded_url.branding_information.try(&.provider_name).should eq("Provider")
    decoded_url.branding_information.try(&.logo).try(&.size).try(&.width).should eq(1920.0)
    response = ContentLauncher::LauncherResponse.new(ContentLauncher::Status::Success, "started")
    ContentLauncher::LauncherResponse.from_tlv(response.to_tlv(nil)).data.should eq("started")
  end

  it "validates feature configuration and command fields before invoking the host" do
    expect_raises(ArgumentError) { launcher(ContentLauncher::Feature::None) }
    expect_raises(ArgumentError) { build(ContentLauncher, feature_map: ContentLauncher::Feature::ContentSearch, accept_header: ["video/mp4"]) }
    expect_raises(ArgumentError) { build(ContentLauncher, feature_map: ContentLauncher::Feature::UrlPlayback, accept_header: ["x" * 1025]) }
    cluster = launcher
    cluster.launch_url(ContentLauncher::LaunchUrlRequest.new("https://example.test/video")).as(Matter::InteractionModel::Status).status.should eq(IMCode::InvalidInState)
    calls = 0
    cluster.on_launch_url do |_request|
      calls += 1
      ContentLauncher::LauncherResponse.new(ContentLauncher::Status::Success)
    end
    cluster.launch_url(ContentLauncher::LaunchUrlRequest.new("x" * 8193)).as(Matter::InteractionModel::Status).status.should eq(IMCode::ConstraintError)
    invalid_color = ContentLauncher::BrandingInformation.new("Provider",
      logo: ContentLauncher::StyleInformation.new(color: "#GGGGGG"))
    cluster.launch_url(ContentLauncher::LaunchUrlRequest.new("https://example.test/video",
      branding_information: invalid_color)).as(Matter::InteractionModel::Status).status.should eq(IMCode::ConstraintError)
    calls.should eq(0)
    valid_color = ContentLauncher::BrandingInformation.new("Provider",
      logo: ContentLauncher::StyleInformation.new(color: "#11223344"))
    cluster.launch_url(ContentLauncher::LaunchUrlRequest.new("https://example.test/video",
      branding_information: valid_color)).as(ContentLauncher::LauncherResponse).status.should eq(ContentLauncher::Status::Success)
    cluster.launch_url(ContentLauncher::LaunchUrlRequest.new("https://example.test/video")).as(ContentLauncher::LauncherResponse).status.should eq(ContentLauncher::Status::Success)
    calls.should eq(2)
  end

  it "rejects revision two preferences unless their feature is advertised" do
    search_only = launcher(ContentLauncher::Feature::ContentSearch)
    search_only.on_launch_content do |_request|
      ContentLauncher::LauncherResponse.new(ContentLauncher::Status::Success)
    end
    search = ContentLauncher::ContentSearch.new([] of ContentLauncher::Parameter)
    advanced = ContentLauncher::PlaybackPreferences.new(playback_position: 1000_u64)
    search_only.launch_content(ContentLauncher::LaunchContentRequest.new(search, true,
      playback_preferences: advanced)).as(Matter::InteractionModel::Status).status.should eq(IMCode::ConstraintError)
    text = ContentLauncher::PlaybackPreferences.new(text_track: ContentLauncher::TrackPreference.new("en"))
    search_only.launch_content(ContentLauncher::LaunchContentRequest.new(search, true,
      playback_preferences: text)).as(Matter::InteractionModel::Status).status.should eq(IMCode::ConstraintError)
    audio = ContentLauncher::PlaybackPreferences.new(audio_tracks: [ContentLauncher::TrackPreference.new("en")])
    search_only.launch_content(ContentLauncher::LaunchContentRequest.new(search, true,
      playback_preferences: audio)).as(Matter::InteractionModel::Status).status.should eq(IMCode::ConstraintError)
    search_only.launch_content(ContentLauncher::LaunchContentRequest.new(search, true)).as(ContentLauncher::LauncherResponse).status.should eq(ContentLauncher::Status::Success)
  end
end
