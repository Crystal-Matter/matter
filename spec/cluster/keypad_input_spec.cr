require "../spec_helper"

private alias KeypadInput = Matter::Cluster::KeypadInput
private alias IMCode = Matter::InteractionModel::StatusCode

private def key_response(cluster : KeypadInput, key_code : UInt8, fabric_index : UInt8? = nil) : KeypadInput::SendKeyResponse
  request = KeypadInput::SendKeyRequest.new(key_code)
  response = invoke(cluster, KeypadInput::CMD_SEND_KEY, request, fabric_index: fabric_index).as(Matter::Cluster::CommandResponse)
  response.command_id.should eq(KeypadInput::CMD_SEND_KEY_RESPONSE)
  KeypadInput::SendKeyResponse.from_tlv(response.response.as(TLV::Any))
end

describe KeypadInput do
  it "advertises the revision-one command and no cluster attributes or events" do
    cluster = build(KeypadInput)
    cluster.cluster_id.id.should eq(0x0509_u32)
    cluster.cluster_revision.should eq(1_u16)
    cluster.attributes.should be_empty
    accepted_command_ids(cluster).should eq([KeypadInput::CMD_SEND_KEY])
    generated_command_ids(cluster).should eq([KeypadInput::CMD_SEND_KEY_RESPONSE])
    cluster.events.should be_empty
    cluster.feature_map.value.should eq(0_u32)
    cluster.get_command_metadata(KeypadInput::CMD_SEND_KEY).as(Matter::Cluster::CommandMetadata).access.should eq(Matter::InteractionModel::EntryPrivilege::Operate)
  end

  it "encodes the CEC code and response status as tag-zero uint8 fields" do
    request = KeypadInput::SendKeyRequest.new(KeypadInput::CecKeyCode::Up.value)
    request.to_tlv(nil).as_structure.keys.should eq([0_u8])
    KeypadInput::SendKeyRequest.from_tlv(request.to_tlv(nil)).key_code.should eq(1_u8)
    response = KeypadInput::SendKeyResponse.new(KeypadInput::Status::UnsupportedKey)
    response.to_tlv(nil).as_structure.keys.should eq([0_u8])
    KeypadInput::SendKeyResponse.from_tlv(response.to_tlv(nil)).status.should eq(KeypadInput::Status::UnsupportedKey)
  end

  it "keeps canonical feature bits and CEC values" do
    features = KeypadInput::Feature::NavigationKeyCodes | KeypadInput::Feature::LocationKeys | KeypadInput::Feature::NumberKeys
    build(KeypadInput, feature_map: features).feature_map.value.should eq(7_u32)
    KeypadInput::CecKeyCode.values.size.should eq(86)
    KeypadInput::CecKeyCode::RootMenu.value.should eq(0x09_u8)
    KeypadInput::CecKeyCode::SetupMenu.value.should eq(0x0A_u8)
    KeypadInput::CecKeyCode::Numbers1.value.should eq(0x21_u8)
    KeypadInput::CecKeyCode::Numbers9.value.should eq(0x29_u8)
    KeypadInput::CecKeyCode::Power.value.should eq(0x40_u8)
    KeypadInput::CecKeyCode::SelectAudioInputFunction.value.should eq(0x6A_u8)
    KeypadInput::CecKeyCode::Data.value.should eq(0x76_u8)
  end

  it "accepts the key codes promised by advertised features" do
    features = KeypadInput::Feature::NavigationKeyCodes |
               KeypadInput::Feature::LocationKeys |
               KeypadInput::Feature::NumberKeys
    cluster = build(KeypadInput, feature_map: features)
    cluster.on_send_key { |_key| KeypadInput::Status::Success }
    [KeypadInput::CecKeyCode::Select, KeypadInput::CecKeyCode::Up,
     KeypadInput::CecKeyCode::Down, KeypadInput::CecKeyCode::Left,
     KeypadInput::CecKeyCode::Right, KeypadInput::CecKeyCode::RootMenu,
     KeypadInput::CecKeyCode::SetupMenu, KeypadInput::CecKeyCode::Exit,
     KeypadInput::CecKeyCode::Number0OrNumber10,
     KeypadInput::CecKeyCode::Numbers9].each do |key|
      key_response(cluster, key.value).status.should eq(KeypadInput::Status::Success)
    end
  end

  it "returns UnsupportedKey for unknown or unavailable codes without invoking the host" do
    cluster = build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::Up])
    seen = [] of KeypadInput::CecKeyCode
    cluster.on_send_key do |code|
      seen << code
      KeypadInput::Status::Success
    end
    key_response(cluster, 0xFF_u8).status.should eq(KeypadInput::Status::UnsupportedKey)
    key_response(cluster, KeypadInput::CecKeyCode::Down.value).status.should eq(KeypadInput::Status::UnsupportedKey)
    seen.should be_empty
    key_response(cluster, KeypadInput::CecKeyCode::Up.value).status.should eq(KeypadInput::Status::Success)
    seen.should eq([KeypadInput::CecKeyCode::Up])
  end

  it "reports invalid current state when a configured key lacks or is refused by the host" do
    cluster = build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::Power])
    key_response(cluster, KeypadInput::CecKeyCode::Power.value).status.should eq(KeypadInput::Status::InvalidKeyInCurrentState)
    cluster.on_send_key { |_key| KeypadInput::Status::InvalidKeyInCurrentState }
    key_response(cluster, KeypadInput::CecKeyCode::Power.value).status.should eq(KeypadInput::Status::InvalidKeyInCurrentState)
    cluster.on_send_key { |_key| KeypadInput::Status::Success }
    key_response(cluster, KeypadInput::CecKeyCode::Power.value).status.should eq(KeypadInput::Status::Success)
  end

  it "rejects malformed requests and invalid capability declarations" do
    cluster = build(KeypadInput)
    expect_status(invoke(cluster, KeypadInput::CMD_SEND_KEY), IMCode::InvalidCommand)
    expect_raises(ArgumentError) do
      build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::Up, KeypadInput::CecKeyCode::Up])
    end
    expect_raises(ArgumentError) { build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::Reserved]) }
    expect_raises(ArgumentError) { build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::SetupMenu]) }
    expect_raises(ArgumentError) { build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::RootMenu]) }
    expect_raises(ArgumentError) { build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::Numbers1]) }
    build(KeypadInput, feature_map: KeypadInput::Feature::NavigationKeyCodes,
      supported_keys: [KeypadInput::CecKeyCode::RootMenu])
    build(KeypadInput, feature_map: KeypadInput::Feature::LocationKeys,
      supported_keys: [KeypadInput::CecKeyCode::RootMenu, KeypadInput::CecKeyCode::SetupMenu])
  end

  it "emits press, hold and release at the 200 ms repeat boundary without sleeping" do
    now = 0.milliseconds
    origin = Time.instant
    timers = [] of {Time::Span, Proc(Nil)}
    cluster = build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::Up],
      clock: -> { origin + now },
      release_timer: ->(delay : Time::Span, callback : Proc(Nil)) { timers << {now + delay, callback}; nil })
    events = [] of {KeypadInput::CecKeyCode, KeypadInput::KeyAction, UInt8?}
    cluster.on_send_key { |_key| KeypadInput::Status::Success }
    cluster.on_key_action { |key, action, fabric| events << {key, action, fabric} }

    key_response(cluster, 1_u8, 1_u8).status.should eq(KeypadInput::Status::Success)
    now = 199.milliseconds
    key_response(cluster, 1_u8, 1_u8).status.should eq(KeypadInput::Status::Success)
    timers.size.should eq(1) # repeats extend the same timer, not spawn one per command
    events.should eq([
      {KeypadInput::CecKeyCode::Up, KeypadInput::KeyAction::Press, 1_u8},
      {KeypadInput::CecKeyCode::Up, KeypadInput::KeyAction::Hold, 1_u8},
    ])
    now = 200.milliseconds
    timers.shift[1].call
    events.size.should eq(2)
    timers.size.should eq(1)
    now = 399.milliseconds
    timers.shift[1].call
    events.last.should eq({KeypadInput::CecKeyCode::Up, KeypadInput::KeyAction::Release, 1_u8})
    key_response(cluster, 1_u8, 1_u8).status.should eq(KeypadInput::Status::Success)
    events.last.should eq({KeypadInput::CecKeyCode::Up, KeypadInput::KeyAction::Press, 1_u8})
  end

  it "keeps keys, fabrics and endpoint instances independent" do
    now = 0.milliseconds
    origin = Time.instant
    timer = ->(_delay : Time::Span, _callback : Proc(Nil)) { nil }
    keys = [KeypadInput::CecKeyCode::Up, KeypadInput::CecKeyCode::Down]
    first = build(KeypadInput, 1, supported_keys: keys, clock: -> { origin + now }, release_timer: timer)
    second = build(KeypadInput, 2, supported_keys: keys, clock: -> { origin + now }, release_timer: timer)
    seen = [] of {UInt16, KeypadInput::CecKeyCode, KeypadInput::KeyAction, UInt8?}
    [first, second].each do |cluster|
      cluster.on_send_key { |_key| KeypadInput::Status::Success }
      cluster.on_key_action { |key, action, fabric| seen << {cluster.endpoint_id.number, key, action, fabric} }
    end
    key_response(first, 1_u8, 1_u8)
    key_response(first, 2_u8, 1_u8)
    key_response(first, 1_u8, 2_u8)
    key_response(second, 1_u8, 1_u8)
    now = 100.milliseconds
    key_response(first, 1_u8, 1_u8)
    seen.last.should eq({1_u16, KeypadInput::CecKeyCode::Up, KeypadInput::KeyAction::Hold, 1_u8})
    now = 200.milliseconds
    first.flush_key_releases
    second.flush_key_releases
    seen.count { |entry| entry[2] == KeypadInput::KeyAction::Release }.should eq(3)
    now = 300.milliseconds
    first.flush_key_releases
    seen.last.should eq({1_u16, KeypadInput::CecKeyCode::Up, KeypadInput::KeyAction::Release, 1_u8})
  end

  it "does not track unsupported or rejected keys and starts fresh after restart" do
    now = 0.milliseconds
    origin = Time.instant
    timer = ->(_delay : Time::Span, _callback : Proc(Nil)) { nil }
    events = [] of KeypadInput::KeyAction
    cluster = build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::Up],
      clock: -> { origin + now }, release_timer: timer)
    cluster.on_send_key { |_key| KeypadInput::Status::InvalidKeyInCurrentState }
    cluster.on_key_action { |_key, action, _fabric| events << action }
    key_response(cluster, 0xFF_u8).status.should eq(KeypadInput::Status::UnsupportedKey)
    key_response(cluster, 1_u8).status.should eq(KeypadInput::Status::InvalidKeyInCurrentState)
    events.should be_empty
    cluster.on_send_key { |_key| KeypadInput::Status::Success }
    key_response(cluster, 1_u8).status.should eq(KeypadInput::Status::Success)
    restarted = build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::Up],
      clock: -> { origin + now }, release_timer: timer)
    restarted.on_send_key { |_key| KeypadInput::Status::Success }
    restarted.on_key_action { |_key, action, _fabric| events << action }
    now = 100.milliseconds
    key_response(restarted, 1_u8).status.should eq(KeypadInput::Status::Success)
    events.should eq([KeypadInput::KeyAction::Press, KeypadInput::KeyAction::Press])
  end

  it "preserves SendKey success and release state when the event callback raises" do
    now = 0.milliseconds
    origin = Time.instant
    callbacks = [] of Proc(Nil)
    cluster = build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::Up],
      clock: -> { origin + now },
      release_timer: ->(_delay : Time::Span, callback : Proc(Nil)) { callbacks << callback; nil })
    cluster.on_send_key { |_key| KeypadInput::Status::Success }
    cluster.on_key_action { |_key, _action, _fabric| raise "host UI failed" }
    key_response(cluster, 1_u8).status.should eq(KeypadInput::Status::Success)
    now = 200.milliseconds
    callbacks.shift.call
    seen = [] of KeypadInput::KeyAction
    cluster.on_key_action { |_key, action, _fabric| seen << action }
    key_response(cluster, 1_u8).status.should eq(KeypadInput::Status::Success)
    seen.should eq([KeypadInput::KeyAction::Press])
  end

  it "does not create a pending press when the acceptance callback fails" do
    now = 0.milliseconds
    origin = Time.instant
    timers = [] of Proc(Nil)
    cluster = build(KeypadInput, supported_keys: [KeypadInput::CecKeyCode::Up],
      clock: -> { origin + now },
      release_timer: ->(_delay : Time::Span, callback : Proc(Nil)) { timers << callback; nil })
    seen = [] of KeypadInput::KeyAction
    cluster.on_key_action { |_key, action, _fabric| seen << action }
    cluster.on_send_key { |_key| raise "acceptance failed" }
    expect_status(invoke(cluster, KeypadInput::CMD_SEND_KEY,
      KeypadInput::SendKeyRequest.new(1_u8)), IMCode::Failure)
    timers.should be_empty
    cluster.on_send_key { |_key| KeypadInput::Status::Success }
    key_response(cluster, 1_u8).status.should eq(KeypadInput::Status::Success)
    seen.should eq([KeypadInput::KeyAction::Press])
  end
end
