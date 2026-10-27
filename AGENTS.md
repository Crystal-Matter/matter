See [CLAUDE.md](CLAUDE.md) — the instructions and conventions for this project live there.

Protocol IDs in production code must be named at every use site. Use the
cluster's generated `CLUSTER_ID`, `ATTR_*`, `CMD_*`, and `EVENT_*` constants,
or a descriptive constant or enum for other protocol values. A comment beside
a numeric literal is not a substitute. Numeric ID literals belong only in the
declarations that define their names. Device composition, protocol logic, and
wire encoders should refer to those names.

```crystal
# Avoid: the comments do not make these IDs self-describing.
required_server_clusters: [0x001D_u32, 0x0054_u32], # Descriptor, RVC Run Mode
required_server_events: {0x0061_u32 => [0x0001_u32]} # OperationCompletion

# Prefer: the references identify the protocol objects themselves.
required_server_clusters: [
  Cluster::Descriptor::CLUSTER_ID,
  Cluster::RvcRunMode::CLUSTER_ID,
],
required_server_events: {
  Cluster::RvcOperationalState::CLUSTER_ID => [
    Cluster::RvcOperationalState::EVENT_OPERATION_COMPLETION,
  ],
}
```
