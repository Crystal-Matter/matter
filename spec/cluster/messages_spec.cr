require "../spec_helper"

private alias Messages = Matter::Cluster::Messages
private alias MessageStatus = Matter::InteractionModel::StatusCode

private class MessagePresentationHost < Messages::Host
  getter queued = [] of {Bytes, UInt8, UInt64?}
  getter cancelled = [] of {Bytes, UInt8}

  def message_queued(message : Messages::Message, origin_node_id : UInt64?, cluster : Messages) : Nil
    @queued << {message.message_id.dup, message.fabric_index, origin_node_id}
  end

  def message_cancelled(message_id : Bytes, fabric_index : UInt8) : Nil
    @cancelled << {message_id.dup, fabric_index}
  end
end

private class ReentrantMessagePresentationHost < Messages::Host
  property removed_fabric : UInt8? = nil
  getter queued = [] of Bytes

  def message_queued(message : Messages::Message, origin_node_id : UInt64?, cluster : Messages) : Nil
    @queued << message.message_id.dup
    if fabric = @removed_fabric
      @removed_fabric = nil
      cluster.remove_fabric(fabric)
    end
  end

  def message_cancelled(message_id : Bytes, fabric_index : UInt8) : Nil
  end
end

private class ReplacingMessagePresentationHost < Messages::Host
  property replacement : Messages::PresentRequest? = nil
  getter seen = [] of String

  def message_queued(message : Messages::Message, origin_node_id : UInt64?, cluster : Messages) : Nil
    @seen << message.text
    if request = @replacement
      @replacement = nil
      cluster.remove_fabric(2_u8)
      cluster.invoke_command(Messages::CMD_PRESENT_MESSAGES_REQUEST, request.to_tlv(nil),
        is_case_session: true, fabric_index: 2_u8)
    end
  end

  def message_cancelled(message_id : Bytes, fabric_index : UInt8) : Nil
  end
end

private def message_id(value : UInt8) : Bytes
  Bytes.new(16, value)
end

private def timed_message(id : Bytes, start_time : UInt32?, duration : UInt64?) : Messages::PresentRequest
  Messages::PresentRequest.new(id, Messages::Priority::Medium, 0_u16, start_time, duration, "Timed")
end

private def present_message(id : Bytes, text : String = "Hello") : Messages::PresentRequest
  Messages::PresentRequest.new(id, Messages::Priority::Medium, 0_u16, nil, nil, text)
end

describe Messages do
  it "declares revision 3 and rejects unsupported feature combinations" do
    cluster = build(Messages)
    cluster.cluster_id.id.should eq(0x0097_u32)
    cluster.cluster_revision.should eq(3_u16)
    read_tlv(cluster, Messages::ATTR_MESSAGES, 1_u8).as_list.should be_empty
    read_tlv(cluster, Messages::ATTR_ACTIVE_MESSAGE_IDS, 1_u8).as_list.should be_empty
    host = MessagePresentationHost.new
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ReceivedConfirmation) }
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ConfirmationResponse) }
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ConfirmationReply) }
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ProtectedMessages) }
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ConfirmationResponse, host: host) }
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ConfirmationReply, host: host) }
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ProtectedMessages, host: host) }
    confirmed = build(Messages, feature_map: Messages::Feature::ReceivedConfirmation, host: host)
    expect_raises(ArgumentError) { confirmed.feature_map = Messages::Feature::None }
    build(Messages, feature_map: Messages::Feature::ReceivedConfirmation |
                                 Messages::Feature::ConfirmationResponse |
                                 Messages::Feature::ConfirmationReply, host: host)
  end

  it "validates choices, replies, and event fields for enabled response profiles" do
    host = MessagePresentationHost.new
    cluster = build(Messages, feature_map: Messages::Feature::ReceivedConfirmation |
                                           Messages::Feature::ConfirmationResponse |
                                           Messages::Feature::ConfirmationReply, host: host)
    events = [] of TLV::Any
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, fabric : UInt8?) do
      events << data if event == Messages::EVENT_MESSAGE_COMPLETE && fabric == 1_u8
      nil
    end
    id = message_id(21_u8)
    control = Messages::CONTROL_CONFIRMATION | Messages::CONTROL_RESPONSE | Messages::CONTROL_REPLY
    request = Messages::PresentRequest.new(id, Messages::Priority::Medium, control, nil, nil,
      "Please respond", [Messages::ResponseOption.new(2_u32, "Yes"), Messages::ResponseOption.new(3_u32, "No")])
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST, request,
      is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    host.queued.should eq([{id, 1_u8, nil}])
    expect_raises(ArgumentError) { cluster.complete(id, 2_u8, 2_u32) }
    expect_raises(ArgumentError) { cluster.complete(id, 1_u8, 4_u32) }
    expect_raises(ArgumentError) { cluster.complete(id, 1_u8, 2_u32, "x" * 257) }
    cluster.present(id, 1_u8)
    cluster.complete(id, 1_u8, 2_u32, "Accepted", Messages::FuturePreference::Allowed)
    fields = events.last.as_structure
    fields.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])
    fields[1_u8].value.should eq(2_u32)
    fields[2_u8].value.should eq("Accepted")
    cluster.messages(1_u8).as(Array(Messages::Message)).should be_empty
  end

  it "persists confirmation state and emits nullable fields on expiry" do
    host = MessagePresentationHost.new
    now_ms = 1_700_000_000_000_i64
    clock = -> { Time.unix_ms(now_ms) }
    cluster = build(Messages, feature_map: Messages::Feature::ReceivedConfirmation |
                                           Messages::Feature::ConfirmationResponse |
                                           Messages::Feature::ConfirmationReply, host: host, clock: clock)
    id = message_id(22_u8)
    request = Messages::PresentRequest.new(id, Messages::Priority::High,
      Messages::CONTROL_CONFIRMATION | Messages::CONTROL_RESPONSE | Messages::CONTROL_REPLY,
      nil, 1_000_u64, "Expires", [] of Messages::ResponseOption)
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST, request,
      is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    cluster.present(id, 1_u8)
    restored = build(Messages, feature_map: Messages::Feature::ReceivedConfirmation |
                                            Messages::Feature::ConfirmationResponse |
                                            Messages::Feature::ConfirmationReply, host: host, clock: clock)
    events = [] of TLV::Any
    restored.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, fabric : UInt8?) do
      events << data if event == Messages::EVENT_MESSAGE_COMPLETE && fabric == 1_u8
      nil
    end
    restored.restore_state(cluster.save_state || fail("Messages state missing"))
    restored.active_message_ids.should eq([id])
    now_ms += 1_000
    restored.process_due_messages
    fields = events.last.as_structure
    fields.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8])
    fields[1_u8].value.should be_nil
    fields[2_u8].value.should be_nil
    fields[3_u8].value.should be_nil
  end

  it "emits only the fields allowed by each advertised profile" do
    host = MessagePresentationHost.new
    {
      {Messages::Feature::ReceivedConfirmation, [0_u8, 3_u8]},
      {Messages::Feature::ReceivedConfirmation | Messages::Feature::ConfirmationResponse, [0_u8, 1_u8, 3_u8]},
      {Messages::Feature::ReceivedConfirmation | Messages::Feature::ConfirmationReply, [0_u8, 2_u8, 3_u8]},
    }.each_with_index do |(features, expected_fields), index|
      cluster = build(Messages, feature_map: features, host: host)
      emitted = [] of TLV::Any
      cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, data : TLV::Any, _fabric : UInt8?) do
        emitted << data if event == Messages::EVENT_MESSAGE_COMPLETE
        nil
      end
      id = message_id((30 + index).to_u8)
      responses = features.confirmation_response? ? [] of Messages::ResponseOption : nil
      request = Messages::PresentRequest.new(id, Messages::Priority::Low, 0_u16, nil, nil, "Notice", responses)
      expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST, request,
        is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
      cluster.complete(id, 1_u8)
      emitted.last.as_structure.keys.should eq(expected_fields)
    end
  end

  it "rejects malformed responses without storing a message" do
    host = MessagePresentationHost.new
    cluster = build(Messages, feature_map: Messages::Feature::ReceivedConfirmation |
                                           Messages::Feature::ConfirmationResponse |
                                           Messages::Feature::ConfirmationReply, host: host)
    id = message_id(40_u8)
    duplicates = [Messages::ResponseOption.new(2_u32, "Yes"), Messages::ResponseOption.new(2_u32, "No")]
    request = Messages::PresentRequest.new(id, Messages::Priority::Medium,
      Messages::CONTROL_RESPONSE, nil, nil, "Question", duplicates)
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST, request,
      is_case_session: true, fabric_index: 1_u8), MessageStatus::InvalidCommand)
    read_tlv(cluster, Messages::ATTR_MESSAGES, 1_u8).as_list.should be_empty
    without_responses = Messages::PresentRequest.new(id, Messages::Priority::Medium,
      Messages::CONTROL_RESPONSE, nil, nil, "Question")
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST, without_responses,
      is_case_session: true, fabric_index: 1_u8), MessageStatus::InvalidCommand)
  end

  it "replays pending messages to the host and dismisses only the removed fabric" do
    host = MessagePresentationHost.new
    features = Messages::Feature::ReceivedConfirmation
    cluster = build(Messages, feature_map: features, host: host)
    first = message_id(41_u8)
    second = message_id(42_u8)
    [{first, 1_u8, 111_u64}, {second, 2_u8, 222_u64}].each do |id, fabric, origin|
      cluster.request_peer_node_id = origin
      request = Messages::PresentRequest.new(id, Messages::Priority::Low,
        Messages::CONTROL_CONFIRMATION, nil, nil, "Notice")
      expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST, request,
        is_case_session: true, fabric_index: fabric), MessageStatus::Success)
    end
    restored = build(Messages, feature_map: features, host: host)
    restored.restore_state(cluster.save_state || fail("Messages state missing"))
    host.queued.clear
    restored.replay_messages_to_host!
    host.queued.should eq([{first, 1_u8, 111_u64}, {second, 2_u8, 222_u64}])
    restored.remove_fabric(1_u8)
    host.cancelled.should eq([{first, 1_u8}])
    restored.messages(2_u8).as(Array(Messages::Message)).map(&.message_id).should eq([second])

    legacy = cluster.save_state || fail("Messages state missing")
    legacy.delete("origin_node_ids")
    legacy_restored = build(Messages, feature_map: features, host: host)
    legacy_restored.restore_state(legacy)
    host.queued.clear
    legacy_restored.replay_messages_to_host!
    host.queued.should eq([{first, 1_u8, nil}, {second, 2_u8, nil}])
  end

  it "does not replay a message removed by an earlier host callback" do
    host = ReentrantMessagePresentationHost.new
    cluster = build(Messages, feature_map: Messages::Feature::ReceivedConfirmation, host: host)
    first = message_id(43_u8)
    removed = message_id(44_u8)
    [{first, 1_u8}, {removed, 2_u8}].each do |id, fabric|
      request = Messages::PresentRequest.new(id, Messages::Priority::Low,
        Messages::CONTROL_CONFIRMATION, nil, nil, "Notice")
      expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST, request,
        is_case_session: true, fabric_index: fabric), MessageStatus::Success)
    end
    host.queued.clear
    restored = build(Messages, feature_map: Messages::Feature::ReceivedConfirmation, host: host)
    restored.restore_state(cluster.save_state || fail("Messages state missing"))
    host.removed_fabric = 2_u8
    restored.replay_messages_to_host!
    host.queued.should eq([first])
    restored.messages(2_u8).as(Array(Messages::Message)).should be_empty
  end

  it "does not replay stale content when a callback replaces the same ID" do
    host = ReplacingMessagePresentationHost.new
    cluster = build(Messages, feature_map: Messages::Feature::ReceivedConfirmation, host: host)
    first = message_id(45_u8)
    replaced = message_id(46_u8)
    [{first, 1_u8, "First"}, {replaced, 2_u8, "Stale"}].each do |id, fabric, text|
      request = Messages::PresentRequest.new(id, Messages::Priority::Low,
        Messages::CONTROL_CONFIRMATION, nil, nil, text)
      expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST, request,
        is_case_session: true, fabric_index: fabric), MessageStatus::Success)
    end
    restored = build(Messages, feature_map: Messages::Feature::ReceivedConfirmation, host: host)
    restored.restore_state(cluster.save_state || fail("Messages state missing"))
    host.seen.clear
    host.replacement = Messages::PresentRequest.new(replaced, Messages::Priority::High,
      Messages::CONTROL_CONFIRMATION, nil, nil, "Fresh")
    restored.replay_messages_to_host!
    host.seen.should eq(["First", "Fresh"])
    restored.messages(2_u8).as(Array(Messages::Message)).first.text.should eq("Fresh")
  end

  it "encodes the fixed 16-byte ID and mandatory nullable fields" do
    request = present_message(message_id(1_u8))
    request.to_tlv(nil).as_structure.keys.should eq([0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8])
    Messages::PresentRequest.from_tlv(request.to_tlv(nil)).message_id.should eq(message_id(1_u8))
    expect_raises(ArgumentError) { present_message(Bytes.new(15, 1_u8)) }
  end

  it "queues and cancels messages within the originating fabric only" do
    cluster = build(Messages)
    event_fabrics = [] of UInt8?
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, _event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, fabric : UInt8?) do
      event_fabrics << fabric
      nil
    end
    id = message_id(2_u8)
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST, present_message(id), is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    read_tlv(cluster, Messages::ATTR_MESSAGES, 1_u8).as_list.size.should eq(1)
    read_tlv(cluster, Messages::ATTR_MESSAGES, 2_u8).as_list.should be_empty
    event_fabrics.should eq([1_u8])

    cancel = Messages::CancelRequest.new([id])
    expect_status(invoke(cluster, Messages::CMD_CANCEL_MESSAGES_REQUEST, cancel, is_case_session: true, fabric_index: 2_u8), MessageStatus::Success)
    read_tlv(cluster, Messages::ATTR_MESSAGES, 1_u8).as_list.size.should eq(1)
    expect_status(invoke(cluster, Messages::CMD_CANCEL_MESSAGES_REQUEST, cancel, is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    read_tlv(cluster, Messages::ATTR_MESSAGES, 1_u8).as_list.should be_empty
  end

  it "rejects unauthenticated commands and enforces the eight-message capacity" do
    cluster = build(Messages)
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST, present_message(message_id(1_u8))), MessageStatus::UnsupportedAccess)
    8.times do |index|
      expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST,
        present_message(message_id(index.to_u8)), is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    end
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST,
      present_message(message_id(9_u8)), is_case_session: true, fabric_index: 2_u8), MessageStatus::ResourceExhausted)
  end

  it "exposes active IDs across fabrics while keeping message details scoped" do
    cluster = build(Messages)
    id = message_id(7_u8)
    other_id = message_id(9_u8)
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST,
      present_message(id), is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST,
      present_message(other_id), is_case_session: true, fabric_index: 2_u8), MessageStatus::Success)
    cluster.present(id, 1_u8)
    cluster.present(other_id, 2_u8)
    read_tlv(cluster, Messages::ATTR_ACTIVE_MESSAGE_IDS, 1_u8).as_list.size.should eq(2)
    read_tlv(cluster, Messages::ATTR_ACTIVE_MESSAGE_IDS, 2_u8).as_list.size.should eq(2)
    read_tlv(cluster, Messages::ATTR_MESSAGES, 1_u8).as_list.size.should eq(1)
    read_tlv(cluster, Messages::ATTR_MESSAGES, 2_u8).as_list.size.should eq(1)
    cluster.complete(id, 1_u8)
    read_tlv(cluster, Messages::ATTR_ACTIVE_MESSAGE_IDS, 2_u8).as_list.size.should eq(1)
    read_tlv(cluster, Messages::ATTR_MESSAGES, 2_u8).as_list.size.should eq(1)
  end

  it "presents a message with no start or duration when the clock advances between reads" do
    now_ms = 1_700_000_000_000_i64
    clock = -> do
      now_ms += 1_i64
      Time.unix_ms(now_ms)
    end
    cluster = build(Messages, clock: clock)
    id = message_id(15_u8)
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST,
      present_message(id), is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)

    cluster.present(id, 1_u8)
    cluster.active_message_ids.should eq([id])
  end

  it "restores queued messages and erases a removed fabric" do
    cluster = build(Messages)
    id = message_id(8_u8)
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST,
      present_message(id), is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    restored = build(Messages)
    restored.restore_state(cluster.save_state || fail("Messages state missing"))
    read_tlv(restored, Messages::ATTR_MESSAGES, 1_u8).as_list.size.should eq(1)
    restored.remove_fabric(1_u8)
    read_tlv(restored, Messages::ATTR_MESSAGES, 1_u8).as_list.should be_empty
  end

  it "blocks early presentation and completes a duration-limited message once" do
    now_ms = 1_700_000_000_000_i64
    clock = -> { Time.unix_ms(now_ms) }
    callbacks = [] of Proc(Nil)
    timer = ->(_delay : Time::Span, callback : Proc(Nil)) { callbacks << callback; nil }
    cluster = build(Messages, clock: clock, expiry_timer: timer)
    events = [] of UInt32
    cluster.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, _fabric : UInt8?) do
      events << event
      nil
    end
    id = message_id(10_u8)
    start = (now_ms // 1000 - 946_684_800 + 2).to_u32
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST,
      timed_message(id, start, 1_000_u64), is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    expect_raises(ArgumentError) { cluster.present(id, 1_u8) }
    now_ms += 2_000
    cluster.present(id, 1_u8)
    cluster.active_message_ids.should eq([id])
    now_ms += 1_000
    callbacks.last.call
    cluster.active_message_ids.should be_empty
    cluster.messages(1_u8).as(Array(Messages::Message)).should be_empty
    events.count(Messages::EVENT_MESSAGE_COMPLETE).should eq(1)
    callbacks.each(&.call)
    events.count(Messages::EVENT_MESSAGE_COMPLETE).should eq(1)
  end

  it "persists the receipt deadline for a null StartTime and cancels pending expiry" do
    now_ms = 1_700_000_000_000_i64
    clock = -> { Time.unix_ms(now_ms) }
    callbacks = [] of Proc(Nil)
    timer = ->(_delay : Time::Span, callback : Proc(Nil)) { callbacks << callback; nil }
    cluster = build(Messages, clock: clock, expiry_timer: timer)
    id = message_id(11_u8)
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST,
      timed_message(id, nil, 2_000_u64), is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    now_ms += 1_000
    restored = build(Messages, clock: clock, expiry_timer: timer)
    restored.restore_state(cluster.save_state || fail("Messages state missing"))
    now_ms += 1_000
    callbacks.last.call
    restored.messages(1_u8).as(Array(Messages::Message)).should be_empty

    other_id = message_id(12_u8)
    expect_status(invoke(restored, Messages::CMD_PRESENT_MESSAGES_REQUEST,
      timed_message(other_id, nil, 1_000_u64), is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    expect_status(invoke(restored, Messages::CMD_CANCEL_MESSAGES_REQUEST,
      Messages::CancelRequest.new([other_id]), is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    now_ms += 1_000
    callbacks.each(&.call)
    restored.messages(1_u8).as(Array(Messages::Message)).should be_empty
  end

  it "completes an overdue message during restore" do
    now_ms = 1_700_000_000_000_i64
    clock = -> { Time.unix_ms(now_ms) }
    callbacks = [] of Proc(Nil)
    timer = ->(_delay : Time::Span, callback : Proc(Nil)) { callbacks << callback; nil }
    cluster = build(Messages, clock: clock, expiry_timer: timer)
    id = message_id(13_u8)
    expect_status(invoke(cluster, Messages::CMD_PRESENT_MESSAGES_REQUEST,
      timed_message(id, nil, 1_000_u64), is_case_session: true, fabric_index: 1_u8), MessageStatus::Success)
    document = cluster.save_state || fail("Messages state missing")
    now_ms += 2_000
    restored = build(Messages, clock: clock, expiry_timer: timer)
    completed = 0
    restored.on_event_emitted = ->(_ep : UInt16, _cl : UInt32, event : UInt32, _priority : Matter::InteractionModel::EventPriority, _data : TLV::Any, fabric : UInt8?) do
      completed += 1 if event == Messages::EVENT_MESSAGE_COMPLETE && fabric == 1_u8
      nil
    end
    restored.restore_state(document)
    restored.messages(1_u8).as(Array(Messages::Message)).should be_empty
    completed.should eq(1)
    callbacks.each(&.call)
    completed.should eq(1)
  end
end
