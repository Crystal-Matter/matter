# Actions server

`Matter::Cluster::Actions` implements the Matter 1.6 Actions cluster (0x0025,
revision 1). Add it to a node endpoint, normally a bridge or aggregator. Supply
`EndpointList` entries and `Action` entries with unique IDs. Every action must
reference an advertised endpoint list and declares which of the twelve commands
it accepts through `CommandBits`. `ActionList` may be empty when the node only
advertises logical endpoint groups.

The cluster does not operate other clusters on its own. Register a host callback
with `on_execute`. It receives the action, command, optional InvokeID, and the
optional transition time or duration. The callback performs the application
work and returns an Interaction Model status. Without a callback, a supported
action invocation returns `InvalidInState` and changes nothing. A missing
ActionID returns `NotFound`; a command omitted from an action's
`SupportedCommands` returns `InvalidCommand`.

The callback parameter is measured in tenths of a second for
`InstantActionWithTransition` and seconds for the four duration commands. On
successful duration expiry, the cluster calls the callback again with the
corresponding ending command before it changes the advertised state. A new
command cancels the previous expiry. For work that completes asynchronously,
the host calls `update_action_state` or `fail_action`; these methods publish
feedback using the latest InvokeID when one was supplied. This API does not
persist host work or scheduled expiries across device restarts; an application
that needs that behavior must restore its own execution state.

`StateChanged` and `ActionFailed` events are emitted only when the most recent
command for that action included InvokeID, as required by the cluster model.
The optional `SetupURL` must be an HTTPS URL with at most 512 ASCII bytes.
