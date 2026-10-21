require "../spec_helper"
require "file_utils"

describe Matter::Session::GroupOutgoingCounters do
  it "reserves durable data and control counters before use and skips unused values after restart" do
    directory = File.join(Dir.tempdir, "matter-group-counter-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    path = File.join(directory, "state.yml")
    begin
      store = Matter::Storage::YamlFile.new(path).tap(&.open)
      first = Matter::Session::GroupOutgoingCounters.new(store)
      data = first.next_data
      control = first.next_control
      first.next_data.should eq(data + 1)
      first.next_control.should eq(control + 1)
      store.close

      reopened = Matter::Storage::YamlFile.new(path).tap(&.open)
      second = Matter::Session::GroupOutgoingCounters.new(reopened)
      second.next_data.should be >= data + 1000
      second.next_control.should be >= control + 1000
      reopened.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "rejects transient stores and refuses a reservation that would wrap" do
    expect_raises(Matter::SessionError) do
      Matter::Session::GroupOutgoingCounters.new(Matter::Storage::Memory.new)
    end
    directory = File.join(Dir.tempdir, "matter-group-counter-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    begin
      store = Matter::Storage::YamlFile.new(File.join(directory, "state.yml")).tap(&.open)
      store.write(Matter::Storage::Collections::DEVICE, "group-outgoing-counters",
        Matter::Storage::Document{"data" => UInt32::MAX.to_i64 - 500_i64, "control" => 1_i64})
      expect_raises(Matter::SessionError) { Matter::Session::GroupOutgoingCounters.new(store) }
      store.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
