require "../spec_helper"

private alias Messages = Matter::Cluster::Messages
private alias MessageStatus = Matter::InteractionModel::StatusCode

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
  it "declares revision 3 and rejects unimplemented optional features" do
    cluster = build(Messages)
    cluster.cluster_id.id.should eq(0x0097_u32)
    cluster.cluster_revision.should eq(3_u16)
    read_tlv(cluster, Messages::ATTR_MESSAGES, 1_u8).as_list.should be_empty
    read_tlv(cluster, Messages::ATTR_ACTIVE_MESSAGE_IDS, 1_u8).as_list.should be_empty
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ReceivedConfirmation) }
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ConfirmationResponse) }
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ConfirmationReply) }
    expect_raises(ArgumentError) { build(Messages, feature_map: Messages::Feature::ProtectedMessages) }
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
