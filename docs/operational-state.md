# Operational State server

`Matter::Cluster::OperationalState` implements the generic Matter 1.6 cluster
0x0060 at revision 3. It can monitor a device without exposing any remote
actuation commands. Device types such as a dishwasher or laundry washer still
need their own mode, alarm and control clusters to meet the full device type
requirements.

The host supplies changes to the physical appliance state:

```crystal
state = Matter::Cluster::OperationalState.new(Matter::DataType::EndpointNumber.new(1_u16))
state.update_phases(["wash", "rinse", "spin"], 0_u8)
state.report_state(Matter::Cluster::OperationalState::RUNNING)
state.update_countdown(900_u32)
state.report_completion(Matter::Cluster::OperationalState::NO_ERROR, 900_u32)
state.report_state(Matter::Cluster::OperationalState::STOPPED)
```

`update_phases` validates the current phase index and enforces the Matter list
and string limits. `update_countdown` enforces the 259,200-second limit; pass
`reportable: false` for ordinary one-second countdown ticks so subscriptions
are not notified for each tick. Call `report_error` with a nonzero error state
to set the Error state and emit the mandatory critical event. After recovery,
call `report_state` to clear the error. `report_completion` emits the optional
information event without changing state; the host reports the final state
separately.

Remote commands must be explicitly enabled. Start requires Stop; Pause and
Resume are enabled as a pair. A configured command without a host callback
returns an operational failure response and does not change the state. The
callback returns `ErrorState.new(NO_ERROR)` only after the appliance accepted
and performed the operation. Other error codes deny it. The server handles
idempotent requests and the standard Pause and Resume compatibility matrix.

```crystal
alias Op = Matter::Cluster::OperationalState
state = Op.new(Matter::DataType::EndpointNumber.new(1_u16),
  supported_commands: [Op::Command::Start, Op::Command::Stop])
state.on_command do |command|
  case command
  when Op::Command::Start
    # Check local authorization and interlocks, then start the appliance.
    Op::ErrorState.new(Op::NO_ERROR)
  when Op::Command::Stop
    # Stop only when the appliance can safely do so.
    Op::ErrorState.new(Op::NO_ERROR)
  else
    Op::ErrorState.new(Op::COMMAND_INVALID_IN_STATE)
  end
end
```

The cluster does not persist live physical state. After a device restart, the
host should publish its measured phases, countdown, state and error. No
appliance example or device type advertises this cluster automatically.
