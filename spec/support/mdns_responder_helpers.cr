# Shared preamble for the `Matter::MDNS::Responder` specs, which are split into
# `spec/mdns/responder_advertisement_spec.cr` and
# `spec/mdns/responder_query_spec.cr`.
require "../../src/matter/mdns/responder"
require "../../src/matter/mdns/service_type"
require "../../src/matter/mdns/record_builder"

def compressed_fabric_id_bytes(compressed_fabric_id : UInt64) : Bytes
  bytes = Bytes.new(sizeof(UInt64))
  IO::ByteFormat::LittleEndian.encode(compressed_fabric_id, bytes)
  bytes
end

# Captures multicast packets instead of sending them so specs can inspect
# announcements and query responses.
class RecordingResponder < Matter::MDNS::Responder
  getter sent = [] of DNS::Packet

  def filter_ipv4_packet(packet : DNS::Packet, source : Socket::IPAddress) : DNS::Packet
    packet_for_ipv4_source(packet, source)
  end

  private def send_multicast(packet : DNS::Packet) : Nil
    @sent << packet
  end
end

# Decode a DNS label-encoded name (as stored in PTR/SRV resource data)
def decode_dns_name(io : IO) : String
  labels = [] of String
  while (length = io.read_byte) && length > 0
    labels << io.read_string(length)
  end
  labels.join('.')
end

# Instance name a PTR record points at
def ptr_target(record : DNS::Packet::ResourceRecord) : String
  decode_dns_name(IO::Memory.new(record.resource_data))
end

# key=value pairs of a TXT record
def txt_entries(record : DNS::Packet::ResourceRecord) : Hash(String, String)
  io = IO::Memory.new(record.resource_data)
  entries = {} of String => String
  while (length = io.read_byte) && length > 0
    key, _, value = io.read_string(length).partition('=')
    entries[key] = value
  end
  entries
end

def ptr_records(packet : DNS::Packet) : Array(DNS::Packet::ResourceRecord)
  packet.answers.select { |record| record.type == Matter::MDNS::RecordBuilder::TYPE_PTR }
end

def txt_record(packet : DNS::Packet) : DNS::Packet::ResourceRecord
  packet.additionals.find! { |record| record.type == Matter::MDNS::RecordBuilder::TYPE_TXT }
end

def query_for(name : String, type : UInt16) : DNS::Packet
  question = DNS::Packet::Question.new(name: name, type: type, class_code: Matter::MDNS::RecordBuilder::CLASS_IN)
  DNS::Packet.new(id: 0_u16, questions: [question])
end

def commissioning_info(discriminator : UInt16, mode : Matter::MDNS::CommissioningMode = Matter::MDNS::CommissioningMode::Enhanced) : Matter::MDNS::CommissioningInfo
  Matter::MDNS::CommissioningInfo.new(
    device_name: "TestDevice",
    vendor_id: 0xFFF1_u16,
    product_id: 0x8001_u16,
    discriminator: discriminator,
    device_type: 15_u16,
    commissioning_mode: mode
  )
end

# Poll until the condition holds or the timeout elapses
def wait_for(timeout : Time::Span, &condition : -> Bool) : Nil
  deadline = Time.monotonic + timeout
  until condition.call || Time.monotonic >= deadline
    sleep 5.milliseconds
  end
end

def recording_responder(burst_interval : Time::Span = Matter::MDNS::Responder::ANNOUNCEMENT_BURST_INTERVAL) : RecordingResponder
  RecordingResponder.new(
    hostname: "test-device.local",
    ip_addresses: [Socket::IPAddress.new("192.168.1.100", 0)],
    announcement_burst_interval: burst_interval
  )
end
