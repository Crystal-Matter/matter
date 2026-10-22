require "./cluster"
require "../storage/record"

module Matter
  module Cluster
    # Matter 1.6 Audio Output server (0x050B), revision 1.
    # The host supplies the physical outputs and may veto a selection before
    # the cluster publishes it. Selected output and user names are nonvolatile.
    class AudioOutput < Base
      cluster 0x050B, revision: 1

      feature :name_updates, bit: 0

      NAME_MAX_BYTES = 32

      enum OutputType : UInt8
        Hdmi      = 0
        Bt        = 1
        Optical   = 2
        Headphone = 3
        Internal  = 4
        Other     = 5
      end

      struct OutputInfo
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter index : UInt8

        @[TLV::Field(tag: 1)]
        getter output_type : OutputType

        @[TLV::Field(tag: 2)]
        getter name : String

        def initialize(@index : UInt8, @output_type : OutputType, @name : String)
          raise ArgumentError.new("output name exceeds 32 UTF-8 bytes") if @name.bytesize > NAME_MAX_BYTES
        end
      end

      struct SelectOutputRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter index : UInt8

        def initialize(@index : UInt8)
        end
      end

      struct RenameOutputRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter index : UInt8

        @[TLV::Field(tag: 1)]
        getter name : String

        def initialize(@index : UInt8, @name : String)
        end
      end

      attribute 0x0000, :output_list, Array(OutputInfo), default: [] of OutputInfo,
        persist: true, validate: :validate_output_list!
      attribute 0x0001, :current_output, UInt8, default: 0_u8,
        persist: true, validate: :validate_current_output!

      command 0x00, :select_output, request: SelectOutputRequest, access: :operate
      command 0x01, :rename_output, request: RenameOutputRequest, access: :manage, requires: :name_updates

      @on_select_output : Proc(OutputInfo, Bool)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     output_list : Array(OutputInfo),
                     current_output : UInt8,
                     @feature_map : Feature = Feature::None)
        validate_catalogue!(output_list, current_output)
        @output_list = output_list.dup
        @current_output = current_output
        @configured_outputs = output_list.dup
        @configured_current_output = current_output
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      # Return false when the underlying device cannot change to this output.
      # Registration reapplies the selected output after persisted state is
      # restored, so the advertised selection matches physical routing.
      def on_select_output(&block : OutputInfo -> Bool) : Nil
        output = @output_list.find { |entry| entry.index == @current_output }
        raise ConfigurationError.new("current audio output is absent") unless output
        unless block.call(output)
          raise ConfigurationError.new("host cannot activate current audio output #{output.index}")
        end
        @on_select_output = block
      end

      def select_output(request : SelectOutputRequest) : InteractionModel::Status
        output = @output_list.find { |entry| entry.index == request.index }
        return InteractionModel::Status.not_found unless output
        callback = @on_select_output
        return InteractionModel::Status.invalid_in_state unless callback && callback.call(output)
        self.current_output = output.index
        InteractionModel::Status.success
      end

      def rename_output(request : RenameOutputRequest) : InteractionModel::Status
        return InteractionModel::Status.constraint_error if request.name.bytesize > NAME_MAX_BYTES
        index = @output_list.index { |entry| entry.index == request.index }
        return InteractionModel::Status.not_found unless index
        original = @output_list[index]
        updated = @output_list.dup
        updated[index] = OutputInfo.new(original.index, original.output_type, request.name)
        self.output_list = updated
        InteractionModel::Status.success
      end

      private def validate_catalogue!(outputs : Array(OutputInfo), current : UInt8) : Nil
        raise ArgumentError.new("audio output list cannot be empty") if outputs.empty?
        indices = outputs.map(&.index)
        raise ArgumentError.new("duplicate audio output index") unless indices.uniq.size == indices.size
        raise ArgumentError.new("current audio output is absent") unless indices.includes?(current)
        raise ArgumentError.new("audio output name exceeds 32 UTF-8 bytes") if outputs.any? { |entry| entry.name.bytesize > NAME_MAX_BYTES }
      end

      private def validate_output_list!(outputs : Array(OutputInfo)) : Nil
        validate_catalogue!(outputs, @current_output)
      end

      private def validate_current_output!(current : UInt8) : Nil
        raise ArgumentError.new("current audio output is absent") unless @output_list.any? { |entry| entry.index == current }
      end

      private def after_restore_state : Nil
        # The physical output catalogue belongs to the host. Restore edited
        # names only for outputs still present, preserving their actual types.
        # If hardware changed, fall back to the host's selected output.
        saved_outputs = @output_list
        @output_list = @configured_outputs.map do |configured|
          saved = saved_outputs.find { |entry| entry.index == configured.index }
          name = saved && saved.output_type == configured.output_type && saved.name.bytesize <= NAME_MAX_BYTES ? saved.name : configured.name
          OutputInfo.new(configured.index, configured.output_type, name)
        end
        @current_output = @configured_current_output unless @output_list.any? { |entry| entry.index == @current_output }
      end
    end
  end
end
