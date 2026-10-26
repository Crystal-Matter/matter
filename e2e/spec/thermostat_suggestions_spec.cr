require "./e2e_helper"

private def suggestion_now : String
  (Time.utc.to_unix - Matter::Cluster::Thermostat::MATTER_EPOCH_UNIX_SECONDS).to_s
end

private def add_suggestion(device : E2E::Device, handle : String, effective : String = suggestion_now) : E2E::Result
  device.chip("thermostat", "add-thermostat-suggestion", handle, effective, "30", device.node, "1")
end

private def suggestion_id(result : E2E::Result) : String
  value = result.value("uniqueID") || raise "AddThermostatSuggestionResponse lacks uniqueID: #{result.tail}"
  value.split(/\s+/).first
end

describe "Matter Thermostat Suggestions guarded fixture" do
  device = E2E::Device["matter_thermostat_suggestions"]

  it "commissions and exposes TSUGGEST metadata and an empty list" do
    device.commission!
    read_int(device, "thermostat", "cluster-revision", "ClusterRevision", 1).should eq(9_i64)
    read_int(device, "thermostat", "feature-map", "FeatureMap", 1).should eq(0x503_i64)
    read_int(device, "thermostat", "max-thermostat-suggestions", "MaxThermostatSuggestions", 1).should eq(5_i64)
    expect_success(device.read("thermostat", "thermostat-suggestions", 1))
    expect_success(device.read("thermostat", "current-thermostat-suggestion", 1))
  end

  it "returns pinned Add and Remove statuses and follows a selected preset" do
    expect_failure(add_suggestion(device, "hex:63"), "NOT_FOUND")
    future = (suggestion_now.to_i64 + 25_i64 * 60_i64 * 60_i64).to_s
    expect_failure(add_suggestion(device, "hex:01", future), "INVALID_COMMAND")
    first = suggestion_id(expect_success(add_suggestion(device, "hex:01")))
    second = suggestion_id(expect_success(add_suggestion(device, "hex:02")))
    begin
      first.should_not eq(second)
      suggestions = expect_success(device.read("thermostat", "thermostat-suggestions", 1)).output
      suggestions.should contain("2 entries")
      current = expect_success(device.read("thermostat", "current-thermostat-suggestion", 1))
      selected_id = current.value("UniqueID") || raise "current suggestion lacks UniqueID: #{current.tail}"
      [first, second].should contain(selected_id)
      selected_handle = current.value("PresetHandle") || raise "current suggestion lacks PresetHandle: #{current.tail}"
      active = expect_success(device.read("thermostat", "active-preset-handle", 1))
      active.value("ActivePresetHandle").should eq(selected_handle)
      expect_failure(device.chip("thermostat", "remove-thermostat-suggestion", "255", device.node, "1"), "NOT_FOUND")
    ensure
      expect_success(device.chip("thermostat", "remove-thermostat-suggestion", first, device.node, "1"))
      expect_success(device.chip("thermostat", "remove-thermostat-suggestion", second, device.node, "1"))
    end
  end

  it "accepts up to MaxThermostatSuggestions and then reports resource exhaustion" do
    ids = Array.new(5) { suggestion_id(expect_success(add_suggestion(device, "hex:01"))) }
    ids.uniq.size.should eq(5)
    expect_failure(add_suggestion(device, "hex:01"), "RESOURCE_EXHAUSTED")
    ids.each do |id|
      expect_success(device.chip("thermostat", "remove-thermostat-suggestion", id, device.node, "1"))
    end
  end
end
