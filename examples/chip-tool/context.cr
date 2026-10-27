require "file_utils"

module ChipTool
  # Command-line context: where the controller keeps its state and how long to
  # wait for devices. The controller state lives in one YAML store,
  # `<storage_directory>/controller.yml`, shared by every command.
  class Context
    UNCOMPRESSED_P256_POINT_TAG = 0x04_u8
    DEFAULT_TIMEOUT             = 10.seconds
    DEFAULT_STORAGE_DIR         = "chip-tool-storage"
    STORAGE_DIR_ENV             = "MATTER_CHIP_TOOL_STORAGE"
    CONTROLLER_STATE_FILE       = "controller.yml"

    getter storage_directory : String
    getter timeout : Time::Span
    getter state_store : Matter::Controller::StateStore

    def case_pairing : Matter::Controller::Pairing::CasePairing
      Matter::Controller::Pairing::CasePairing.new(
        resumption_store: Matter::Session::Case::ResumptionStore.new(@state_store.backend))
    end

    def initialize(@storage_directory : String, @timeout : Time::Span = DEFAULT_TIMEOUT)
      FileUtils.mkdir_p(@storage_directory)
      backend = Matter::Storage::YamlFile.new(File.join(@storage_directory, CONTROLLER_STATE_FILE))
      @state_store = Matter::Controller::StateStore.new(backend)
    end

    def self.parse(argv : Array(String)) : {Context, Array(String)}
      args = argv.dup

      storage_dir = ENV[STORAGE_DIR_ENV]? || File.join(Dir.current, DEFAULT_STORAGE_DIR)
      timeout = DEFAULT_TIMEOUT
      fabric_id = nil.as(UInt64?)
      root_public_key = nil.as(Bytes?)
      controller_node_id = nil.as(UInt64?)

      i = 0
      while i < args.size
        case args[i]
        when "--storage-directory"
          value = args[i + 1]?
          raise ArgumentError.new("missing value for --storage-directory") unless value
          storage_dir = value
          args.delete_at(i)
          args.delete_at(i)
          next
        when "--timeout"
          value = args[i + 1]?
          raise ArgumentError.new("missing value for --timeout") unless value
          timeout = value.to_f64.seconds
          args.delete_at(i)
          args.delete_at(i)
          next
        when "--fabric-id"
          value = args[i + 1]?
          raise ArgumentError.new("missing value for --fabric-id") unless value
          fabric_id = parse_node_id(value)
          args.delete_at(i)
          args.delete_at(i)
          next
        when "--root-public-key"
          value = args[i + 1]?
          raise ArgumentError.new("missing value for --root-public-key") unless value
          root_public_key = value.hexbytes
          raise ArgumentError.new("root public key must be a 65-byte uncompressed P-256 point") unless root_public_key.size == 65 && root_public_key[0] == UNCOMPRESSED_P256_POINT_TAG
          args.delete_at(i)
          args.delete_at(i)
          next
        when "--controller-node-id"
          value = args[i + 1]?
          raise ArgumentError.new("missing value for --controller-node-id") unless value
          controller_node_id = parse_node_id(value)
          args.delete_at(i)
          args.delete_at(i)
          next
        end
        i += 1
      end

      if (root_public_key || controller_node_id) && fabric_id.nil?
        raise ArgumentError.new("--root-public-key and --controller-node-id require --fabric-id")
      end

      context = new(storage_dir, timeout)
      if id = fabric_id
        state = context.state_store.load
        state.select_fabric(id, root_public_key, controller_node_id)
        context.state_store.save(state)
      end
      {context, args}
    end

    private def self.parse_node_id(value : String) : UInt64
      id = if value.starts_with?("0x") || value.starts_with?("0X")
             value[2..].to_u64?(16)
           else
             value.to_u64?
           end
      id || raise ArgumentError.new("invalid fabric or controller Node ID: #{value}")
    end
  end
end
