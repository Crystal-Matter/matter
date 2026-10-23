class Sample
  cluster 0x1234, revision: 3
  command 0x00, :present
  command 0x02, :feature_command, requires: :test
  command 0x04, :wrapped_command, request: WrappedRequest,
    requires: [:test, :other]
  command 0x05, :multiline_gate,
    requires: [:test, :other,
               :third]
  event 0x02, :feature_event, priority: :info
  event 0x03, :wrapped_event, priority: :info,
    requires: :test, payload: WrappedEvent
end
