# Crystal chip-tool (WIP)

This is a small Crystal-native controller CLI built on top of this library, loosely modeled after `connectedhomeip/examples/chip-tool`.

## Build

```bash
CRYSTAL_CACHE_DIR=./tmp/.crystal_cache crystal build examples/chip-tool.cr -o ./bin/chip-tool-crystal
```

## Usage

All commands are invoked as:

```bash
./bin/chip-tool-crystal <cluster|command-set> <command> [args...] [--storage-directory <dir>] [--timeout <seconds>]
```

`--storage-directory` persists controller state (the fabric, its certificates, the known nodes and
the unsecured message counter) to `controller.yml` inside that directory, through
`Matter::Storage::YamlFile`. `bin/matter-storage inspect yaml:<dir>/controller.yml` prints it with
the keys and certificates redacted.

## Pairing

Commission a device over IP using a manual pairing code:

```bash
./bin/chip-tool-crystal pairing code 0x1 1495-753-5193 --allow-test-attestation
```

To skip mDNS discovery and target a specific address:

```bash
./bin/chip-tool-crystal pairing code 0x1 1495-753-5193 --address 192.168.1.50:5540 --allow-test-attestation
```

For a Wi-Fi or Thread device already reachable over IP, pass regulatory
information so the commissioner can issue `SetRegulatoryConfig` when its
Network Commissioning feature map requires it:

```bash
./bin/chip-tool-crystal pairing code 0x1 1495-753-5193 --regulatory-location indoor --country-code AU
```

The example devices use the public Matter test PAA and CD signer. The
`--allow-test-attestation` flag explicitly opts in to those credentials.
The controller rejects commissioning without a configured attestation verifier;
applications commissioning production devices must provide their own trusted
PAA certificates and CD signer keys through `AttestationTrustStore`.
The current verifier supports the compact CD CMS profile without signed
attributes; it rejects other CMS profiles. Production trust stores also need
an explicit revocation provider. An unavailable revocation result rejects the
device. The opt-in test fixture reports `Good` only for local examples.

## OnOff

Read the `OnOff` attribute:

```bash
./bin/chip-tool-crystal onoff read on-off 0x1 1
```

Send commands:

```bash
./bin/chip-tool-crystal onoff on 0x1 1
./bin/chip-tool-crystal onoff off 0x1 1
./bin/chip-tool-crystal onoff toggle 0x1 1
```

