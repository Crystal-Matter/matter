require "../spec_helper"

private ENDPOINT =      1_u16
private CLUSTER  = 0x0101_u32
private EVENT_A  =   0x02_u32
private EVENT_B  =   0x03_u32

private def payload(value : Int) : TLV::Any
  TLV::Any.new(value.to_u32, nil)
end

private def journal_with(count : Int32, priority : Matter::InteractionModel::EventPriority) : Matter::EventJournal
  journal = Matter::EventJournal.new
  count.times { |index| journal.record(ENDPOINT, CLUSTER, EVENT_A, priority, payload(index)) }
  journal
end

private def any_path : Array(Matter::InteractionModel::EventPath)
  [Matter::InteractionModel::EventPath.new]
end

describe Matter::EventJournal do
  describe "#record" do
    it "does not publish or consume an event number when durable counter storage fails" do
      saved = [] of UInt64
      fail_write = true
      journal = Matter::EventJournal.new(->(next_number : UInt64) do
        raise Matter::StorageError.new("counter write failed") if fail_write
        saved << next_number
        nil
      end)

      expect_raises(Matter::StorageError) do
        journal.record(ENDPOINT, CLUSTER, EVENT_A, :info, payload(1))
      end
      journal.size.should eq(0)
      journal.next_event_number.should eq(1_u64)

      fail_write = false
      journal.record(ENDPOINT, CLUSTER, EVENT_A, :info, payload(2)).event_number.should eq(1_u64)
      saved.should eq([2_u64])
    end

    it "numbers events from one, node wide, across endpoints and clusters" do
      journal = Matter::EventJournal.new
      journal.latest_event_number.should eq(0_u64)

      first = journal.record(ENDPOINT, CLUSTER, EVENT_A, :info, payload(1))
      second = journal.record(2_u16, 0x0028_u32, EVENT_B, :critical, payload(2))

      first.event_number.should eq(Matter::EventJournal::FIRST_EVENT_NUMBER)
      second.event_number.should eq(Matter::EventJournal::FIRST_EVENT_NUMBER + 1)
      journal.latest_event_number.should eq(second.event_number)
      journal.size.should eq(2)
    end

    it "stamps the record with its origin, priority and fabric" do
      journal = Matter::EventJournal.new
      record = journal.record(ENDPOINT, CLUSTER, EVENT_A, :critical, payload(7), fabric_index: 3_u8)

      record.endpoint.should eq(ENDPOINT)
      record.cluster.should eq(CLUSTER)
      record.event.should eq(EVENT_A)
      record.priority.critical?.should be_true
      record.fabric_index.should eq(3_u8)
      record.data.as_u64.should eq(7)
      record.epoch_timestamp_ms.should be > 0_u64
    end
  end

  describe "ring buffers" do
    it "keeps each priority within its own capacity" do
      Matter::EventJournal.capacity(:debug).should eq(Matter::EventJournal::DEBUG_CAPACITY)
      Matter::EventJournal.capacity(:info).should eq(Matter::EventJournal::INFO_CAPACITY)
      Matter::EventJournal.capacity(:critical).should eq(Matter::EventJournal::CRITICAL_CAPACITY)

      journal = journal_with(Matter::EventJournal::DEBUG_CAPACITY + 5, :debug)
      journal.size.should eq(Matter::EventJournal::DEBUG_CAPACITY)

      # The oldest five were evicted, the newest kept, and numbering continued
      records = journal.query(any_path)
      records.first.event_number.should eq(6_u64)
      records.last.event_number.should eq((Matter::EventJournal::DEBUG_CAPACITY + 5).to_u64)
    end

    it "does not let a flood of debug events evict a critical one" do
      journal = Matter::EventJournal.new
      critical = journal.record(ENDPOINT, CLUSTER, EVENT_B, :critical, payload(0))
      (Matter::EventJournal::DEBUG_CAPACITY * 2).times do |index|
        journal.record(ENDPOINT, CLUSTER, EVENT_A, :debug, payload(index))
      end

      journal.query(any_path).map(&.event_number).should contain(critical.event_number)
    end
  end

  describe "#query" do
    it "returns records in event number order regardless of priority" do
      journal = Matter::EventJournal.new
      journal.record(ENDPOINT, CLUSTER, EVENT_A, :debug, payload(1))
      journal.record(ENDPOINT, CLUSTER, EVENT_A, :critical, payload(2))
      journal.record(ENDPOINT, CLUSTER, EVENT_A, :info, payload(3))

      journal.query(any_path).map(&.event_number).should eq([1_u64, 2_u64, 3_u64])
    end

    it "selects nothing without paths" do
      journal = journal_with(3, :info)

      journal.query(nil).should be_empty
      journal.query([] of Matter::InteractionModel::EventPath).should be_empty
    end

    it "honours endpoint, cluster and event wildcards" do
      journal = Matter::EventJournal.new
      journal.record(ENDPOINT, CLUSTER, EVENT_A, :info, payload(1))
      journal.record(2_u16, CLUSTER, EVENT_B, :info, payload(2))

      journal.query([Matter::InteractionModel::EventPath.new(endpoint: ENDPOINT)]).size.should eq(1)
      journal.query([Matter::InteractionModel::EventPath.new(cluster: CLUSTER)]).size.should eq(2)
      journal.query([Matter::InteractionModel::EventPath.new(event: EVENT_B)]).map(&.endpoint).should eq([2_u16])
      journal.query([Matter::InteractionModel::EventPath.new(endpoint: ENDPOINT, cluster: CLUSTER, event: EVENT_B)]).should be_empty
    end

    it "skips records above nothing when after is given" do
      journal = journal_with(4, :info)

      journal.query(any_path, after: 2_u64).map(&.event_number).should eq([3_u64, 4_u64])
      journal.query(any_path, min_event_number: 3_u64).map(&.event_number).should eq([3_u64, 4_u64])
    end

    it "hides a fabric scoped record from other fabrics but not a node scoped one" do
      journal = Matter::EventJournal.new
      journal.record(ENDPOINT, CLUSTER, EVENT_A, :info, payload(1), fabric_index: 1_u8)
      journal.record(ENDPOINT, CLUSTER, EVENT_B, :info, payload(2))

      journal.query(any_path, fabric_index: 1_u8).map(&.event).should eq([EVENT_A, EVENT_B])
      journal.query(any_path, fabric_index: 2_u8).map(&.event).should eq([EVENT_B])
      journal.query(any_path).map(&.event).should eq([EVENT_B])
    end
  end

  describe "#each" do
    it "yields what query returns" do
      journal = journal_with(3, :info)

      yielded = [] of UInt64
      journal.each(any_path, after: 1_u64) { |record| yielded << record.event_number }
      yielded.should eq([2_u64, 3_u64])
    end
  end

  describe "#clear" do
    it "drops the records but never reuses an event number" do
      journal = journal_with(3, :info)
      journal.clear

      journal.size.should eq(0)
      journal.record(ENDPOINT, CLUSTER, EVENT_A, :info, payload(9)).event_number.should eq(4_u64)
    end
  end

  describe Matter::EventJournal::Record do
    it "reports urgency only for a matching urgent path" do
      journal = Matter::EventJournal.new
      record = journal.record(ENDPOINT, CLUSTER, EVENT_A, :info, payload(1))

      urgent_match = Matter::InteractionModel::EventPath.new(endpoint: ENDPOINT, is_urgent: true)
      urgent_other = Matter::InteractionModel::EventPath.new(endpoint: 9_u16, is_urgent: true)
      calm = Matter::InteractionModel::EventPath.new(endpoint: ENDPOINT)

      record.urgent_for?([urgent_match]).should be_true
      record.urgent_for?([urgent_other]).should be_false
      record.urgent_for?([calm]).should be_false
    end

    it "builds the concrete path a report carries" do
      journal = Matter::EventJournal.new
      path = journal.record(ENDPOINT, CLUSTER, EVENT_A, :info, payload(1)).to_path

      path.endpoint.should eq(ENDPOINT)
      path.cluster.should eq(CLUSTER)
      path.event.should eq(EVENT_A)
      path.is_urgent?.should be_false
    end
  end
end
