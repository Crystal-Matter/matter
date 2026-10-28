require "big"
require "log"
require "json"
require "time/instant"

require "tlv"
require "verhoeff"

module Matter
  {% begin %}
    VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
  {% end %}

  # Fallback logger for files that do not define their own `Log` constant.
  Log = ::Log.for("matter")
end

require "./matter/error"

# Subsystems are loaded in dependency order: lower layers first.
require "./matter/hex"
require "./matter/datatype"
require "./matter/interaction_model"
require "./matter/codec"
require "./matter/crypto"
require "./matter/certificate"
require "./matter/storage"
require "./matter/debouncer"
require "./matter/fabric"
require "./matter/fabric_table"
require "./matter/network"
require "./matter/transport"
require "./matter/session"
require "./matter/commissioning"
require "./matter/cluster"
require "./matter/commissioning/joint_fabric_administrator_service"
require "./matter/commissioning/joint_fabric_add_noc_policy"
require "./matter/protocol"
require "./matter/mdns"
require "./matter/device_type"
require "./matter/endpoint"
require "./matter/event_journal"
require "./matter/node"
require "./matter/camera_composition"
require "./matter/setup_payload"
require "./matter/device"
