require "option_parser"
require "json"
require "file_utils"
require "colorize"

module DeviceValidationProtocolIds
  GLOBAL_GENERATED_COMMAND_LIST = 0xFFF8_u32
  GLOBAL_ACCEPTED_COMMAND_LIST  = 0xFFF9_u32
  GLOBAL_ATTRIBUTE_LIST         = 0xFFFB_u32
  GLOBAL_FEATURE_MAP            = 0xFFFC_u32
  GLOBAL_CLUSTER_REVISION       = 0xFFFD_u32
  CASE_AUTH_MODE                =       2_u8
  ADMINISTER_PRIVILEGE          =       5_u8
  DEFAULT_DEVICE_ENDPOINT_ID    =      1_u16
end

# Device validation helper that shells out to `chip-tool`.
#
# Intended usage (after pairing with `chip-tool`):
#   crystal run examples/device_validation.cr
#
# Or, with a custom chip-tool path:
#   crystal run examples/device_validation.cr -- --chip-tool /path/to/chip-tool

record ChipResult, args : Array(String), exit_code : Int32, stdout : String, stderr : String do
  def ok? : Bool
    exit_code == 0
  end

  def output : String
    "#{stdout}\n#{stderr}"
  end
end

record CheckResult, name : String, ok : Bool, details : String

def strip_ansi(s : String) : String
  # Remove ANSI color codes commonly emitted by chip-tool.
  s.gsub(/\e\[[0-9;]*m/, "")
end

def run_chip_tool(chip_tool : String, args : Array(String), storage_dir : String? = nil) : ChipResult
  # Many chip-tool builds accept `--storage-directory` as an option that must appear
  # after the required positional arguments (see chip-tool docs).
  final_args = if storage_dir && args.first? != "storage"
                 args + ["--storage-directory", storage_dir]
               else
                 args
               end

  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(chip_tool, final_args, output: stdout, error: stderr)
  ChipResult.new(final_args, status.exit_code, stdout.to_s, stderr.to_s)
end

def extract_bool(output : String, label : String) : Bool?
  text = strip_ansi(output)
  # Example line: "[TOO]   OnOff: TRUE"
  if m = text.match(/#{Regex.escape(label)}:\s*(TRUE|FALSE)\b/i)
    m[1].upcase == "TRUE"
  end
end

def extract_uint_list_from_attribute_list(output : String) : Array(UInt32)?
  text = strip_ansi(output)
  return unless text.includes?("AttributeList:")

  values = [] of UInt32
  text.each_line do |line|
    # Example line: "[TOO]     [10]: 65533 (ClusterRevision)"
    if m = line.match(/\[\d+\]:\s*(\d+)\b/)
      values << m[1].to_u32
    end
  end
  values
end

def check_command_ok(name : String, result : ChipResult) : CheckResult
  return CheckResult.new(name, true, "ok") if result.ok?

  text = strip_ansi(result.output)
  summary = text.each_line.select do |line|
    line.includes?("Run command failure") ||
      line.includes?("Secure Pairing Failed") ||
      line.includes?("Failed to verify peer") ||
      line.includes?("Failed to open pairing window") ||
      line.includes?("Error: IM Error") ||
      line.includes?("IM Error") ||
      line.includes?("Incorrect state") ||
      line.includes?("Timeout") ||
      line.includes?("ERROR") ||
      line.includes?("[TOO] Error")
  end.to_a.last? || text.lines.last? || "unknown error"

  CheckResult.new(name, false, "chip-tool exited #{result.exit_code}: #{summary}")
end

def parse_u64(s : String) : UInt64?
  v = s.strip
  return if v.empty?
  if v.starts_with?("0x") || v.starts_with?("0X")
    v[2..].to_u64?(16)
  else
    # Prefer decimal when the string is digits-only; otherwise allow hex without 0x.
    return v.to_u64? if v.each_char.all?(&.in?('0'..'9'))
    v.to_u64?(16) || v.to_u64?
  end
end

def extract_commissioning_pairing_code(output : String) : String?
  text = strip_ansi(output)

  # Common chip-tool output:
  #   Manual pairing code: [1495-753-5193]
  #   Manual pairing code: 1495-753-5193
  #   Manual pairing code: 34970112332
  if m = text.match(/Manual pairing code:\s*\[?([0-9]{4}-[0-9]{3}-[0-9]{4})\]?/i)
    return m[1]
  end
  if m = text.match(/Manual pairing code:\s*\[?([0-9]{11})\]?/i)
    return m[1]
  end
  if m = text.match(/\b([0-9]{4}-[0-9]{3}-[0-9]{4})\b/)
    return m[1]
  end
  nil
end

record FabricIndexInfo, node_id : UInt64, fabric_index : UInt8

def extract_fabric_indices(output : String) : Array(FabricIndexInfo)
  text = strip_ansi(output)
  results = [] of FabricIndexInfo
  current_node : UInt64? = nil
  current_index : UInt8? = nil

  text.each_line do |line|
    if m = line.match(/\bNodeId:\s*(0x[0-9a-fA-F]+|[0-9a-fA-F]{16}|[0-9]+)\b/i)
      current_node = parse_u64(m[1])
    end

    if m = line.match(/\bFabricIndex:\s*(\d+)\b/i)
      current_index = m[1].to_u8?
    end

    if current_node && current_index
      results << FabricIndexInfo.new(current_node.as(UInt64), current_index.as(UInt8))
      current_node = nil
      current_index = nil
    end
  end

  results
end

record AclEntryInfo, fabric_index : UInt8, privilege : UInt8, auth_mode : UInt8, subjects : Array(UInt64)

def extract_acl_entries(output : String) : Array(AclEntryInfo)
  text = strip_ansi(output)
  entries = [] of AclEntryInfo

  current_fabric : UInt8? = nil
  current_privilege : UInt8? = nil
  current_auth : UInt8? = nil
  current_subjects = [] of UInt64
  in_subjects = false

  flush = -> do
    if current_fabric && current_privilege && current_auth
      entries << AclEntryInfo.new(current_fabric.as(UInt8), current_privilege.as(UInt8), current_auth.as(UInt8), current_subjects.dup)
    end
    current_fabric = nil
    current_privilege = nil
    current_auth = nil
    current_subjects.clear
    in_subjects = false
  end

  text.each_line do |line|
    if line.match(/\bFabricIndex:\s*\d+\b/i) && current_fabric
      flush.call
    end

    if m = line.match(/\bFabricIndex:\s*(\d+)\b/i)
      current_fabric = m[1].to_u8?
    end

    # Examples:
    #   Privilege: 5
    #   Privilege: Administer (5)
    if m = line.match(/\bPrivilege:\s*(?:[A-Za-z]+\s*\()?(\d+)\)?\b/i)
      current_privilege = m[1].to_u8?
    end

    # Examples:
    #   AuthMode: 2
    #   AuthMode: CASE (2)
    if m = line.match(/\bAuthMode:\s*(?:[A-Za-z]+\s*\()?(\d+)\)?\b/i)
      current_auth = m[1].to_u8?
    end

    if line.match(/\bSubjects\b/i)
      in_subjects = true
      next
    end

    if in_subjects
      # End of list (varies by chip-tool formatting)
      # chip-tool prints subjects as e.g. "[1]: 112233" so we can't treat any "]" as list-end.
      if line.strip.in?("]", "],") || line.match(/\bTargets\b/i)
        in_subjects = false
      end

      subject_text = nil.as(String?)

      # Most common: "[1]: 112233"
      if m = line.match(/\[\d+\]:\s*(0x[0-9a-fA-F]+|[0-9a-fA-F]{16}|[0-9]+)\b/)
        subject_text = m[1]
      else
        # Fall back to the last numeric token on the line (avoids capturing timestamps like "[pid:tid]").
        tokens = line.scan(/\b0x[0-9a-fA-F]+\b|\b[0-9a-fA-F]{16}\b|\b\d+\b/)
        if last = tokens.last?
          subject_text = last[0]
        end
      end

      if subject_text && (subject = parse_u64(subject_text))
        current_subjects << subject
      end
    end
  end

  flush.call
  entries
end

def expected_access_denied?(result : ChipResult) : Bool
  return true unless result.ok?
  text = strip_ansi(result.output).upcase
  return true if text.includes?("UNSUPPORTED_ACCESS")
  return true if text.includes?("ACCESS_DENIED")
  return true if text.includes?("UNSUPPORTED ACCESS")
  false
end

def build_view_only_acl_json(subject : UInt64, endpoint_id : UInt16) : String
  JSON.build do |json|
    json.array do
      json.object do
        json.field "privilege", 1 # View
        json.field "authMode", 2  # CASE
        json.field "subjects" do
          json.array { json.number subject }
        end
        # Allow read-only access to basic attributes useful for controllers + the target cluster.
        json.field "targets" do
          json.array do
            # OnOff (cluster 6) on endpoint X
            json.object do
              json.field "endpoint", endpoint_id
              json.field "cluster", 6
              json.field "deviceType", nil
            end
            # Descriptor (cluster 29) and BasicInformation (cluster 40) on endpoint 0
            json.object do
              json.field "endpoint", 0
              json.field "cluster", 29
              json.field "deviceType", nil
            end
            json.object do
              json.field "endpoint", 0
              json.field "cluster", 40
              json.field "deviceType", nil
            end
          end
        end
      end
    end
  end
end

chip_tool = ENV["CHIP_TOOL"]? || "chip-tool"
node_id = "1"
endpoint_id = "1"
node_id_b = nil.as(String?)
storage_dir_a = nil.as(String?)
storage_dir_b = "tmp/device_validation/chip-tool-b-#{Random::Secure.hex(8)}"
open_window_timeout_s = 300
pairing_code_override = nil.as(String?)
peer_address = ENV["MATTER_PEER_ADDRESS"]?

OptionParser.parse do |parser|
  parser.banner = "Usage: device_validation [options] [node_id_a] [endpoint_id] (defaults: 1 1)"
  parser.on("--chip-tool PATH", "Path to chip-tool (default: chip-tool, or env CHIP_TOOL)") { |path| chip_tool = path }
  parser.on("--storage-a DIR", "chip-tool storage directory for Fabric A (passed via --storage-directory)") { |dir| storage_dir_a = dir }
  parser.on("--storage-b DIR", "chip-tool storage directory for Fabric B (default: tmp/device_validation/chip-tool-b-<random>)") { |dir| storage_dir_b = dir }
  parser.on("--address ADDR", "Override peer address for commissioning (ip[:port], also respects env MATTER_PEER_ADDRESS)") { |addr| peer_address = addr }
  parser.on("--node-id-b NODEID", "Operational node id to assign the device in Fabric B (default: node_id_a+1)") { |nodeid| node_id_b = nodeid }
  parser.on("--open-window-timeout SECONDS", "Commissioning window timeout seconds (default: 300)") { |seconds| open_window_timeout_s = seconds.to_i }
  parser.on("--pairing-code CODE", "Skip opening a commissioning window and use this manual pairing code for Fabric B commissioning") { |code| pairing_code_override = code }
  parser.on("-h", "--help", "Show help") do
    puts parser
    exit 0
  end

  parser.invalid_option do |flag|
    STDERR.puts "Unknown option: #{flag}"
    STDERR.puts parser
    exit 2
  end

  parser.unknown_args do |args|
    node_id = args[0]? || node_id
    endpoint_id = args[1]? || endpoint_id
  end
end

checks = [] of CheckResult

def run_check(
  checks : Array(CheckResult),
  chip_tool : String,
  storage_dir : String?,
  name : String,
  args : Array(String),
  & : ChipResult -> CheckResult
)
  print name
  result = run_chip_tool(chip_tool, args, storage_dir: storage_dir)
  check = yield result
  checks << check
  if check.ok
    puts " [passed]".colorize(:green)
  else
    puts " [failed]".colorize(:red)
    STDERR.puts "FAIL: #{check.name} - #{check.details}"
    STDERR.puts "--- chip-tool stdout ---"
    STDERR.puts strip_ansi(result.stdout)
    STDERR.puts "--- chip-tool stderr ---"
    STDERR.puts strip_ansi(result.stderr)
  end
end

run_check(checks, chip_tool, storage_dir_a, "basicinformation.vendor-name", ["basicinformation", "read", "vendor-name", node_id, "0"]) do |cmd_result|
  check_command_ok("basicinformation.vendor-name", cmd_result)
end

run_check(checks, chip_tool, storage_dir_a, "descriptor.parts-list", ["descriptor", "read", "parts-list", node_id, "0"]) do |cmd_result|
  next check_command_ok("descriptor.parts-list", cmd_result) unless cmd_result.ok?
  text = strip_ansi(cmd_result.output)
  if text.match(/\bPartsList:\s*\d+\s+entries\b/) && text.match(/\[\d+\]:\s*#{Regex.escape(endpoint_id)}\b/)
    CheckResult.new("descriptor.parts-list", true, "endpoint #{endpoint_id} present")
  else
    CheckResult.new("descriptor.parts-list", false, "endpoint #{endpoint_id} missing from PartsList")
  end
end

initial_on_off = nil.as(Bool?)
run_check(checks, chip_tool, storage_dir_a, "onoff.on-off (read)", ["onoff", "read", "on-off", node_id, endpoint_id]) do |cmd_result|
  next check_command_ok("onoff.on-off (read)", cmd_result) unless cmd_result.ok?
  value = extract_bool(cmd_result.output, "OnOff")
  if value.is_a?(Bool)
    initial_on_off = value
    CheckResult.new("onoff.on-off (read)", true, "OnOff=#{value}")
  else
    CheckResult.new("onoff.on-off (read)", false, "could not parse OnOff value")
  end
end

run_check(checks, chip_tool, storage_dir_a, "onoff.attribute-list", ["onoff", "read", "attribute-list", node_id, endpoint_id]) do |cmd_result|
  next check_command_ok("onoff.attribute-list", cmd_result) unless cmd_result.ok?

  list = extract_uint_list_from_attribute_list(cmd_result.output)
  unless list
    next CheckResult.new("onoff.attribute-list", false, "could not parse AttributeList")
  end

  duplicates = list.group_by(&.itself).select { |_, v| v.size > 1 }.keys
  unless duplicates.empty?
    next CheckResult.new("onoff.attribute-list", false, "duplicates found: #{duplicates.sort.join(", ")}")
  end

  required = [
    DeviceValidationProtocolIds::GLOBAL_GENERATED_COMMAND_LIST,
    DeviceValidationProtocolIds::GLOBAL_ACCEPTED_COMMAND_LIST,
    DeviceValidationProtocolIds::GLOBAL_ATTRIBUTE_LIST,
    DeviceValidationProtocolIds::GLOBAL_FEATURE_MAP,
    DeviceValidationProtocolIds::GLOBAL_CLUSTER_REVISION,
  ]
  missing = required.reject { |id| list.includes?(id) }
  unless missing.empty?
    next CheckResult.new("onoff.attribute-list", false, "missing required global attributes: #{missing.join(", ")}")
  end

  CheckResult.new("onoff.attribute-list", true, "ok (#{list.size} attrs)")
end

run_check(checks, chip_tool, storage_dir_a, "onoff.toggle", ["onoff", "toggle", node_id, endpoint_id]) do |cmd_result|
  check_command_ok("onoff.toggle", cmd_result)
end

run_check(checks, chip_tool, storage_dir_a, "onoff.on-off (read after toggle)", ["onoff", "read", "on-off", node_id, endpoint_id]) do |cmd_result|
  next check_command_ok("onoff.on-off (read after toggle)", cmd_result) unless cmd_result.ok?
  new_value = extract_bool(cmd_result.output, "OnOff")
  if new_value.nil? || initial_on_off.nil?
    next CheckResult.new("onoff.on-off (read after toggle)", false, "invalid state, no value should be nil: initial: #{initial_on_off.inspect}, toggled: #{new_value.inspect}")
  else
    if new_value == initial_on_off
      next CheckResult.new("onoff.on-off (read after toggle)", false, "toggle did not change OnOff (still #{new_value})")
    end
  end
  CheckResult.new("onoff.on-off (read after toggle)", true, "OnOff=#{new_value.inspect}")
end

# -----------------------------------------------------------------------------
# Multi-fabric + commissioning window + ACL validation
# -----------------------------------------------------------------------------

node_id_a_u64 = parse_u64(node_id)
node_id_b ||= begin
  if node_id_a_u64
    (node_id_a_u64 + 1).to_s
  else
    "2"
  end
end

endpoint_u16 = endpoint_id.to_u16? || DeviceValidationProtocolIds::DEFAULT_DEVICE_ENDPOINT_ID

pairing_code = pairing_code_override
window_discriminator = Random.rand(0..4095).to_s
begin
  Dir.mkdir_p(File.dirname(storage_dir_b))
rescue
end

# Always start Fabric B with a clean chip-tool fabric store so we actually create a second fabric.
b_storage_ready = false
begin
  FileUtils.rm_rf(storage_dir_b)
  Dir.mkdir_p(storage_dir_b)
  b_storage_ready = true
  checks << CheckResult.new("fabric-b.storage.clear-all", true, "cleared #{storage_dir_b}")
rescue ex
  checks << CheckResult.new("fabric-b.storage.clear-all", false, "failed to reset #{storage_dir_b}: #{ex.message}")
end

unless b_storage_ready
  checks << CheckResult.new("commissioning.fabric-b.pairing-code", false, "skipped: Fabric B storage not cleared (storage_dir_b=#{storage_dir_b})")
  checks << CheckResult.new("operationalcredentials.fabrics", false, "skipped: Fabric B storage not cleared")
  checks << CheckResult.new("accesscontrol.acl (discover subjects)", false, "skipped: Fabric B storage not cleared")
  pairing_code = nil
end

if pairing_code.nil? && b_storage_ready
  # Best-effort: close any existing commissioning window so repeated runs don't
  # fail with BUSY.
  begin
    result = run_chip_tool(chip_tool, ["administratorcommissioning", "revoke-commissioning", node_id, "0"], storage_dir: storage_dir_a)
    if result.ok?
      checks << CheckResult.new("commissioning.revoke-window", true, "revoked")
    else
      checks << CheckResult.new("commissioning.revoke-window", true, "skipped (already closed or revoke failed)")
    end
  rescue ex
    checks << CheckResult.new("commissioning.revoke-window", true, "skipped (exception: #{ex.message})")
  end

  # Some chip-tool versions require: node-id option window-timeout iteration discriminator
  # Use option=1 (enhanced window) so chip-tool outputs an ephemeral pairing code.
  run_check(checks, chip_tool, storage_dir_a, "commissioning.open-window", ["pairing", "open-commissioning-window", node_id, "1", open_window_timeout_s.to_s, "1000", window_discriminator]) do |cmd_result|
    next check_command_ok("commissioning.open-window", cmd_result) unless cmd_result.ok?
    code = extract_commissioning_pairing_code(cmd_result.output)
    if code
      pairing_code = code
      CheckResult.new("commissioning.open-window", true, "pairing_code=#{code} discriminator=#{window_discriminator}")
    else
      CheckResult.new("commissioning.open-window", false, "could not extract pairing code from chip-tool output")
    end
  end
else
  checks << CheckResult.new("commissioning.open-window", true, "skipped (pairing_code provided)") if pairing_code
end

if pairing_code && b_storage_ready
  pairing_args = ["pairing", "code", node_id_b.as(String), pairing_code.as(String)]
  if addr = peer_address
    supports_address = ENV["CHIP_TOOL_SUPPORTS_ADDRESS"]?
    supports_address = "1" if supports_address.nil? && File.basename(chip_tool) == "chip-tool-crystal"
    if supports_address == "1"
      pairing_args += ["--address", addr]
      pairing_args << "--allow-test-attestation"
    end
  end

  run_check(checks, chip_tool, storage_dir_b, "commissioning.fabric-b.pairing-code", pairing_args) do |cmd_result|
    check_command_ok("commissioning.fabric-b.pairing-code", cmd_result)
  end

  fabric_index_a = nil.as(UInt8?)
  fabric_index_b = nil.as(UInt8?)

  run_check(checks, chip_tool, storage_dir_a, "operationalcredentials.fabrics", ["operationalcredentials", "read", "fabrics", node_id, "0", "--fabric-filtered", "false"]) do |cmd_result|
    next check_command_ok("operationalcredentials.fabrics", cmd_result) unless cmd_result.ok?
    infos = extract_fabric_indices(cmd_result.output)
    if node_id_a_u64 && (idx = infos.find { |fabric_info| fabric_info.node_id == node_id_a_u64 })
      fabric_index_a = idx.fabric_index
    end
    if node_id_b_u64 = parse_u64(node_id_b.as(String))
      # Node IDs can be reused across fabrics; pick the most recently allocated fabric index.
      matches = infos.select { |fabric_info| fabric_info.node_id == node_id_b_u64 }
      if idx = matches.max_by?(&.fabric_index)
        fabric_index_b = idx.fabric_index
      end
    end

    if fabric_index_a && fabric_index_b
      CheckResult.new("operationalcredentials.fabrics", true, "fabric_a=#{fabric_index_a} fabric_b=#{fabric_index_b}")
    else
      CheckResult.new("operationalcredentials.fabrics", false, "could not determine fabric indices (a=#{fabric_index_a.inspect} b=#{fabric_index_b.inspect})")
    end
  end

  subject_a = nil.as(UInt64?)
  subject_b = nil.as(UInt64?)

  run_check(checks, chip_tool, storage_dir_a, "accesscontrol.acl.fabric-a (discover admin)", ["accesscontrol", "read", "acl", node_id, "0"]) do |cmd_result|
    next check_command_ok("accesscontrol.acl.fabric-a (discover admin)", cmd_result) unless cmd_result.ok?
    entries = extract_acl_entries(cmd_result.output)
    entry = entries.find { |acl_entry| acl_entry.auth_mode == DeviceValidationProtocolIds::CASE_AUTH_MODE && acl_entry.privilege >= DeviceValidationProtocolIds::ADMINISTER_PRIVILEGE && !acl_entry.subjects.empty? }
    subject_a = entry.try(&.subjects.first?)
    if subject_a
      CheckResult.new("accesscontrol.acl.fabric-a (discover admin)", true, "subject_a=#{subject_a}")
    else
      CheckResult.new("accesscontrol.acl.fabric-a (discover admin)", false, "no Administer CASE entry found for Fabric A")
    end
  end

  run_check(checks, chip_tool, storage_dir_b, "accesscontrol.acl.fabric-b (discover admin)", ["accesscontrol", "read", "acl", node_id_b.as(String), "0"]) do |cmd_result|
    next check_command_ok("accesscontrol.acl.fabric-b (discover admin)", cmd_result) unless cmd_result.ok?
    entries = extract_acl_entries(cmd_result.output)
    entry = entries.find { |acl_entry| acl_entry.auth_mode == DeviceValidationProtocolIds::CASE_AUTH_MODE && acl_entry.privilege >= DeviceValidationProtocolIds::ADMINISTER_PRIVILEGE && !acl_entry.subjects.empty? }
    subject_b = entry.try(&.subjects.first?)
    if subject_b
      CheckResult.new("accesscontrol.acl.fabric-b (discover admin)", true, "subject_b=#{subject_b}")
    else
      CheckResult.new("accesscontrol.acl.fabric-b (discover admin)", false, "no Administer CASE entry found for Fabric B")
    end
  end

  if subject_b
    view_only_acl = build_view_only_acl_json(subject_b.as(UInt64), endpoint_u16)
    run_check(checks, chip_tool, storage_dir_b, "accesscontrol.write-acl.fabric-b (set view-only)", ["accesscontrol", "write", "acl", view_only_acl, node_id_b.as(String), "0"]) do |cmd_result|
      check_command_ok("accesscontrol.write-acl.fabric-b (set view-only)", cmd_result)
    end

    run_check(checks, chip_tool, storage_dir_b, "fabric-b.basicinformation.vendor-name (view)", ["basicinformation", "read", "vendor-name", node_id_b.as(String), "0"]) do |cmd_result|
      check_command_ok("fabric-b.basicinformation.vendor-name (view)", cmd_result)
    end

    run_check(checks, chip_tool, storage_dir_b, "fabric-b.descriptor.parts-list (view)", ["descriptor", "read", "parts-list", node_id_b.as(String), "0"]) do |cmd_result|
      check_command_ok("fabric-b.descriptor.parts-list (view)", cmd_result)
    end

    run_check(checks, chip_tool, storage_dir_b, "fabric-b.onoff.on-off (view)", ["onoff", "read", "on-off", node_id_b.as(String), endpoint_id]) do |cmd_result|
      next check_command_ok("fabric-b.onoff.on-off (view)", cmd_result) unless cmd_result.ok?
      value = extract_bool(cmd_result.output, "OnOff")
      if value.nil?
        CheckResult.new("fabric-b.onoff.on-off (view)", false, "could not parse OnOff value")
      else
        CheckResult.new("fabric-b.onoff.on-off (view)", true, "OnOff=#{value}")
      end
    end

    run_check(checks, chip_tool, storage_dir_b, "fabric-b.onoff.on (should be denied)", ["onoff", "on", node_id_b.as(String), endpoint_id]) do |cmd_result|
      if expected_access_denied?(cmd_result)
        CheckResult.new("fabric-b.onoff.on (should be denied)", true, "denied as expected")
      else
        CheckResult.new("fabric-b.onoff.on (should be denied)", false, "expected access denied/unsupported access but command appeared to succeed")
      end
    end

    run_check(checks, chip_tool, storage_dir_b, "fabric-b.accesscontrol.read-acl (should be denied)", ["accesscontrol", "read", "acl", node_id_b.as(String), "0"]) do |cmd_result|
      if expected_access_denied?(cmd_result)
        CheckResult.new("fabric-b.accesscontrol.read-acl (should be denied)", true, "denied as expected")
      else
        CheckResult.new("fabric-b.accesscontrol.read-acl (should be denied)", false, "expected access denied/unsupported access but read appeared to succeed")
      end
    end

    run_check(checks, chip_tool, storage_dir_a, "fabric-a.onoff.toggle (still allowed)", ["onoff", "toggle", node_id, endpoint_id]) do |cmd_result|
      check_command_ok("fabric-a.onoff.toggle (still allowed)", cmd_result)
    end
  end
end

passed = checks.all?(&.ok)
if passed
  puts "PASS (#{checks.size} checks)"
  exit 0
else
  failed = checks.count { |check| !check.ok }
  puts "FAIL (#{failed}/#{checks.size} checks)"
  if pairing_code
    STDERR.puts "Note: last pairing_code=#{pairing_code} discriminator=#{window_discriminator}"
  end
  exit 1
end
