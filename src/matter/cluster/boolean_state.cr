require "./cluster"

module Matter
  module Cluster
    # Boolean State Cluster (0x0045)
    #
    # Exposes a read-only boolean state and optional StateChange events.
    # Commonly used by contact sensors.
    class BooleanState < Base
      cluster 0x0045, revision: 3

      feature :change_event, bit: 0 # CHGEVENT

      struct StateChangeEvent
        include TLV::Serializable

        @[TLV::Field(tag: 0)]
        getter? state_value : Bool

        def initialize(@state_value : Bool)
        end
      end

      attribute 0x0000, :state_value, Bool, default: false, on_change: :report_state_change

      event 0x00, :state_change, priority: :info, requires: :change_event, payload: StateChangeEvent

      def initialize(endpoint_id : DataType::EndpointNumber, @state_value : Bool = false,
                     @feature_map : Feature = Feature::ChangeEvent)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
      end

      # Reports a new reading; `state_value=` with a device-facing name.
      def update_state(value : Bool) : Nil
        self.state_value = value
      end

      # Called with the previous and the new value whenever the state changes.
      def on_state_changed(&block : Bool, Bool -> Nil) : Nil
        on_state_value_changed(&block)
      end

      private def report_state_change(value : Bool) : Nil
        emit_state_change(StateChangeEvent.new(value)) if feature_map.change_event?
      end
    end
  end
end
