require "./cluster"
require "../storage/record"

module Matter
  module Cluster
    # Matter 1.6 Media Input server (0x0507). The host owns physical input
    # switching and input-status presentation; the cluster exposes the catalog.
    class MediaInput < Base
      cluster 0x0507, revision: 1

      feature :name_updates, bit: 0

      enum InputType : UInt8
        Internal  =  0
        Aux       =  1
        Coax      =  2
        Composite =  3
        Hdmi      =  4
        Input     =  5
        Line      =  6
        Optical   =  7
        Video     =  8
        Scart     =  9
        Usb       = 10
        Other     = 11
      end

      struct InputInfo
        include TLV::Serializable
        include Storage::Record

        @[TLV::Field(tag: 0)]
        getter index : UInt8

        @[TLV::Field(tag: 1)]
        getter input_type : InputType

        @[TLV::Field(tag: 2)]
        getter name : String

        @[TLV::Field(tag: 3)]
        getter description : String

        # Stored locally so a changed host default is not mistaken for a user rename.
        # This field has no TLV tag and is never exposed in InputList.
        getter? user_renamed : Bool = false

        def initialize(@index : UInt8, @input_type : InputType, @name : String, @description : String,
                       @user_renamed : Bool = false)
        end
      end

      struct SelectInputRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter index : UInt8

        def initialize(@index : UInt8)
        end
      end

      struct RenameInputRequest
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter index : UInt8

        @[TLV::Field(tag: 1)]
        getter name : String

        def initialize(@index : UInt8, @name : String)
        end
      end

      attribute 0x0000, :input_list, Array(InputInfo),
        default: [] of InputInfo, persist: true, validate: :validate_input_list!
      attribute 0x0001, :current_input, UInt8,
        default: 0_u8, persist: true, validate: :validate_current_input!

      command 0x00, :select_input, request: SelectInputRequest,
        access: :operate
      command 0x01, :show_input_status, access: :operate
      command 0x02, :hide_input_status, access: :operate
      command 0x03, :rename_input, request: RenameInputRequest,
        access: :manage, requires: :name_updates

      @select_input_callback : Proc(UInt8, InteractionModel::Status)?
      @input_status_callback : Proc(Bool, InteractionModel::Status)?

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     input_list : Array(InputInfo) = [] of InputInfo,
                     current_input : UInt8? = nil)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        raise ArgumentError.new("Media Input requires at least one input") if input_list.empty?
        raise ArgumentError.new("Media Input indices must be unique") unless input_list.map(&.index).to_set.size == input_list.size
        @current_input = current_input || input_list.first.index
        raise ArgumentError.new("CurrentInput must name an input") unless input_list.any? { |input| input.index == @current_input }
        @input_list = input_list.dup
        @configured_inputs = input_list.dup
        @configured_current_input = @current_input
      end

      def on_select_input(&block : UInt8 -> InteractionModel::Status) : Nil
        @select_input_callback = block
      end

      def on_input_status(&block : Bool -> InteractionModel::Status) : Nil
        @input_status_callback = block
      end

      def select_input(request : SelectInputRequest) : InteractionModel::Status
        return InteractionModel::Status.not_found unless @input_list.any? { |input| input.index == request.index }
        callback = @select_input_callback
        return InteractionModel::Status.invalid_in_state unless callback
        status = callback.call(request.index)
        self.current_input = request.index if status.success?
        status
      end

      def show_input_status : InteractionModel::Status
        @input_status_callback.try(&.call(true)) || InteractionModel::Status.invalid_in_state
      end

      def hide_input_status : InteractionModel::Status
        @input_status_callback.try(&.call(false)) || InteractionModel::Status.invalid_in_state
      end

      def rename_input(request : RenameInputRequest) : InteractionModel::Status
        return InteractionModel::Status.not_found unless @input_list.any? { |input| input.index == request.index }
        self.input_list = @input_list.map do |input|
          input.index == request.index ? InputInfo.new(input.index, input.input_type, request.name, input.description, true) : input
        end
        InteractionModel::Status.success
      end

      private def validate_input_list!(list : Array(InputInfo)) : Nil
        raise ArgumentError.new("Media Input requires at least one input") if list.empty?
        raise ArgumentError.new("Media Input indices must be unique") unless list.map(&.index).to_set.size == list.size
        raise ArgumentError.new("CurrentInput must name an input") unless list.any? { |input| input.index == @current_input }
      end

      private def validate_current_input!(index : UInt8) : Nil
        raise ArgumentError.new("CurrentInput must name an input") unless @input_list.any? { |input| input.index == index }
      end

      private def after_restore_state : Nil
        # The host's catalogue represents the physical inputs. Keep an edited
        # name only when its index and type still identify the same input.
        saved_inputs = @input_list
        @input_list = @configured_inputs.map do |configured|
          saved = saved_inputs.find { |input| input.index == configured.index && input.input_type == configured.input_type }
          renamed = @feature_map.name_updates? && saved.try(&.user_renamed?) == true
          name = if renamed && saved
                   saved.name
                 else
                   configured.name
                 end
          InputInfo.new(configured.index, configured.input_type, name, configured.description, renamed)
        end
        @current_input = @configured_current_input unless @input_list.any? { |input| input.index == @current_input }
      end
    end
  end
end
