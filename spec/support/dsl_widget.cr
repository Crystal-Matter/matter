# The spec-local cluster exercising every keyword of the cluster DSL,
# shared by the dsl_*_spec.cr files.
require "../spec_helper"

# A spec-local cluster exercising every keyword of the cluster DSL.
module DslSpec
  enum Mode : UInt8
    Idle   = 0
    Active = 1
    Fault  = 2
  end

  struct PingRequest
    include TLV::Serializable

    @[TLV::Field(tag: 0)]
    property count : UInt8

    def initialize(@count : UInt8)
    end
  end

  struct PingResponse
    include TLV::Serializable

    @[TLV::Field(tag: 0)]
    property echoed : UInt8

    def initialize(@echoed : UInt8)
    end
  end

  class Widget < Matter::Cluster::Base
    cluster 0xFFF1_FC10, revision: 3

    ALPHA_OR_BETA = [:alpha, :beta]

    feature :alpha, bit: 0
    feature :beta, bit: 1
    feature :gamma, bit: 2
    conflicts :beta, :gamma

    attribute 0x0000, :enabled, Bool, default: false, callback: :new_only
    attribute 0x0001, :level, UInt8, default: 10_u8, writable: true, min: 1, max: 100
    attribute 0x0002, :label, String, default: "widget", writable: true, max_length: 8
    attribute 0x0003, :mode, Mode, default: Mode::Idle, writable: true, persist: false
    attribute 0x0004, :offset, Int16, default: 0_i16, writable: true, min: -100, max: 100
    attribute 0x0005, :setpoint, UInt16, nullable: true, writable: true
    attribute 0x0006, :serial, String, default: "SN-1", fixed: true
    attribute 0x0007, :alpha_only, UInt8, default: 1_u8, writable: true, requires: :alpha
    attribute 0x0008, :not_beta, UInt8, default: 2_u8, requires: {beta: false}
    attribute 0x0009, :alpha_or_beta_without_gamma, UInt8, default: 3_u8, requires: [:alpha, {beta: true, gamma: false}]
    attribute 0x000A, :secret, UInt8, default: 0_u8, writable: true, persist: false, read_access: :operate, write_access: :manage
    attribute 0x000B, :counter, UInt32, default: 0_u32, persist: true, optional: true, scene: true, omit_changes: true, timed: true, fabric_scoped: true
    attribute 0x000C, :guarded, UInt8, default: 0_u8, writable: true, persist: false
    attribute 0x000D, :mirror, UInt8, default: 0_u8
    attribute 0x000E, :uptime, UInt32, computed: true
    attribute 0x000F, :fabric_view, Array(UInt8), computed: true, fabric_scoped: true
    attribute 0x0010, :state, Mode, computed: true
    attribute 0x0011, :raw, UInt8, computed: true
    attribute 0x0012, :store, UInt8, computed: true, writable: true, max: 50
    attribute 0x0013, :maybe, UInt8, nullable: true, optional: true, present_if: :maybe
    attribute 0x0014, :gated, UInt8, default: 0_u8, writable: true, present_if: :gate_open?
    attribute 0x0015, :tag, String, default: "", writable: true
    attribute 0x0016, :alpha_or_beta, UInt8, default: 0_u8, requires: ALPHA_OR_BETA

    before_write :guarded do |value|
      Matter::InteractionModel::Status.constraint_error if value.odd?
    end

    before_write :tag do |value|
      value.empty? ? Matter::InteractionModel::Status.constraint_error : value.upcase
    end

    after_write :guarded do
      self.mirror = @guarded
    end

    command 0x00, :ping, request: PingRequest, response: PingResponse, response_id: 0x01
    command 0x02, :reset
    command 0x03, :alpha_command, requires: :alpha
    command 0x04, :unimplemented, optional: true
    command 0x05, :implemented_optional, optional: true
    command 0x06, :guarded_command, timed: true, access: :manage
    command 0x07, :echo, request: PingRequest, response: PingResponse, response_id: 0x01
    command 0x08, :fallible, request: PingRequest, response: PingResponse, response_id: 0x09
    command 0x09, :set_thing, request: PingRequest, handler: :handle_set_thing
    command 0x0A, :whoami

    event 0x00, :tripped, priority: :critical
    event 0x01, :noted
    event 0x02, :alpha_event, requires: :alpha

    property uptime : UInt32 = 0_u32
    property? raw_ready : Bool = false
    property? gate_open : Bool = false
    getter store_value : UInt8 = 0_u8
    getter seen_fabric : UInt8?
    getter seen_session : UInt64?
    getter? seen_case : Bool = false

    def fabric_view(fabric_index : UInt8?) : Array(UInt8)
      fabric_index ? [fabric_index] : [] of UInt8
    end

    def state : Mode
      Mode::Active
    end

    def raw : TLV::Any | Matter::InteractionModel::Status
      @raw_ready ? TLV::Any.new(9_u8) : Matter::InteractionModel::Status.failure
    end

    def store : UInt8
      @store_value
    end

    def store=(value : UInt8) : Nil
      @store_value = value
    end

    def handle_set_thing(request : PingRequest) : Matter::InteractionModel::Status
      self.level = request.count
      Matter::InteractionModel::Status.success
    end

    def whoami : Matter::InteractionModel::Status
      @seen_fabric = request_fabric_index
      @seen_session = request_session_id
      @seen_case = request_is_case_session?
      Matter::InteractionModel::Status.success
    end

    def ping(request : PingRequest) : PingResponse
      PingResponse.new(request.count)
    end

    def reset : Matter::InteractionModel::Status
      self.level = 10_u8
      Matter::InteractionModel::Status.success
    end

    def alpha_command : Matter::InteractionModel::Status
      Matter::InteractionModel::Status.success
    end

    def implemented_optional : Matter::Cluster::CommandResponse
      Matter::Cluster::CommandResponse.new(CMD_IMPLEMENTED_OPTIONAL, nil)
    end

    def guarded_command : Matter::InteractionModel::Status
      Matter::InteractionModel::Status.busy
    end

    def echo(request : PingRequest) : PingResponse
      PingResponse.new(request.count)
    end

    def fallible(request : PingRequest) : Matter::InteractionModel::Status | PingResponse
      return Matter::InteractionModel::Status.invalid_command if request.count.zero?
      PingResponse.new(request.count)
    end
  end

  # A renamed cluster that persists by hand.
  class Gadget < Matter::Cluster::Base
    cluster 0xFFF1_FC12, revision: 1, name: "Renamed", persist_state: false

    attribute 0x0000, :knob, UInt8, default: 0_u8, writable: true
  end

  class CopiedList < Matter::Cluster::Base
    cluster 0xFFF1_FC13, revision: 1

    attribute 0x0000, :items, Array(UInt8), default: [] of UInt8, copy_on_assign: true
  end
end
