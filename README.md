# Matter

[![CI](https://github.com/Crystal-Matter/matter/actions/workflows/ci.yml/badge.svg)](https://github.com/Crystal-Matter/matter/actions/workflows/ci.yml)

A Matter 1.6 library in Crystal for building devices and controllers.

## Install

Add to `shard.yml`, then run `shards install`:

```yaml
dependencies:
  matter:
    github: Crystal-Matter/matter
```

## Start here

Run the switch example; it prints a setup code for commissioning:

```sh
crystal run examples/matter_switch_device.cr
```

| Task | Entry point | Next step |
| --- | --- | --- |
| Build a device | `require "matter"` | [Device guide](docs/extended-guide.md#building-a-device) and [examples](examples/) |
| Commission or control devices | `require "matter/controller"` | [Controller guide](docs/extended-guide.md#controller) and [chip-tool CLI](examples/chip-tool/README.md) |
| Share fabrics across administrators | Device and controller Joint Fabric APIs | [Matter 1.6 Joint Fabric guide](docs/matter_1_6_joint_fabric.md) |
| Persist state | YAML, JSON, or memory by default; SQLite and PostgreSQL opt in | [Storage guide](docs/extended-guide.md#storage) |

## Scope

The library includes PASE and CASE sessions, discovery, commissioning, Interaction Model, subscriptions, and device and controller runtimes. It declares all 135 standard Matter 1.6 clusters in the pinned XML audit. Declaration coverage does **not** establish complete behavior or certification; consult the [cluster audit](docs/protocol-coverage.md) and [command and event audit](docs/protocol-command-event-coverage.md) before using a feature.

| Area | Details |
| --- | --- |
| Devices | Declarative endpoints and clusters, fabric-aware access, events, and durable state |
| Controllers | Discovery, pairing, commissioning, reads, writes, invokes, and subscriptions |
| Joint Fabrics | Administrator and Datastore roles, shared controller identities, migration, and interop fixtures |
| Transport | UDP by default; experimental BlueZ BTP central adapter |
| Storage | YAML, JSON, memory; explicit SQLite or PostgreSQL adapters with shared SQL schema |

## Documentation

| Guide | Covers |
| --- | --- |
| [Detailed usage](docs/extended-guide.md) | Device DSL, controller APIs, shared fabrics, storage, examples, and testing |
| [Architecture](docs/architecture.md) | How messages move through the stack |
| [Joint Fabric](docs/matter_1_6_joint_fabric.md) | Matter 1.6 behavior, interoperability evidence, and remaining deployment requirements |
| [Cluster coverage](docs/protocol-coverage.md) | Declarations, revisions, and limits of the audit |
| [Command and event coverage](docs/protocol-command-event-coverage.md) | Mandatory ID comparison and its limits |

The full end-to-end suite runs with `./test`; see [testing options](docs/extended-guide.md#end-to-end-tests). Contributions are welcome through [pull requests](docs/extended-guide.md#contributing).

MIT licensed. Created and maintained by [Stephen von Takach](https://github.com/stakach).
