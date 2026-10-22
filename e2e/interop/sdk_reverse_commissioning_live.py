#!/usr/bin/env python3
"""Official Matter 1.6 FabricAdmin/Bridge reverse-commissioning E2E.

The SDK's real FabricAdmin requests CommissionerControl approval, receives the
Crystal response, opens its local bridge window over Pigweed RPC, and Crystal
commissions that bridge onto its pre-existing source fabric. No RPC responses
or Matter packets are simulated.
"""

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

from sdk_jfc_switch_smoke import ManagedProcess


SDK_BRIDGE_PIN = "20202021"
SDK_BRIDGE_DISCRIMINATOR = "3841"
SDK_BRIDGE_PORT = 5533
CRYSTAL_PORT = 5540
SDK_ADMIN_RPC_PORT = 33001
SDK_BRIDGE_RPC_PORT = 33002
SDK_BRIDGE_NODE_ID = 1
CRYSTAL_NODE_ID = 2


def command(argv, log_path, timeout=300):
    with log_path.open("wb") as output:
        result = subprocess.run(argv, stdout=output, stderr=subprocess.STDOUT,
                                timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f"command exited {result.returncode}: {' '.join(map(str, argv))}; "
                           f"log tail:\n{log_path.read_text(errors='replace')[-5000:]}")
    return log_path.read_text(errors="replace")


def await_output(process, pattern, timeout, since=0):
    deadline = time.monotonic() + timeout
    expression = re.compile(pattern, re.IGNORECASE)
    while time.monotonic() < deadline:
        match = expression.search(process.output, since)
        if match:
            return match
        if process.process.poll() is not None:
            break
        time.sleep(0.2)
    raise RuntimeError(f"{process.name}: missing {pattern!r}; log tail:\n{process.output[-5000:]}")


def run(args):
    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    sdk = args.sdk.resolve()
    bridge_bin = sdk / "objdir-reverse/linux-x64-fabric-bridge-ipv6only-no-ble-no-wifi-clang-rpc/fabric-bridge-app"
    admin_bin = sdk / "objdir-reverse/linux-x64-fabric-admin-ipv6only-no-ble-no-wifi-clang-rpc/fabric-admin"
    for binary in (bridge_bin, admin_bin, args.aggregator, args.driver):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError(f"missing executable: {binary}")

    source_state = logs / "source-controller.yml"
    source_state.unlink(missing_ok=True)
    command([str(args.driver), "setup", str(source_state)], logs / "source-setup.log")

    processes = []
    try:
        bridge_state = logs / "sdk-bridge-state"
        admin_state = logs / "sdk-admin-state"
        crystal_state = logs / "crystal-state"
        for directory in (bridge_state, admin_state, crystal_state):
            directory.mkdir(exist_ok=True)
        kvs = bridge_state / "kvs"
        kvs.touch(exist_ok=True)

        bridge = ManagedProcess("sdk-bridge", [str(bridge_bin),
            "--KVS", str(kvs), "--discriminator", SDK_BRIDGE_DISCRIMINATOR,
            "--passcode", SDK_BRIDGE_PIN, "--secured-device-port", str(SDK_BRIDGE_PORT),
            "--fabric-admin-server-port", str(SDK_ADMIN_RPC_PORT),
            "--local-server-port", str(SDK_BRIDGE_RPC_PORT)], bridge_state, logs)
        processes.append(bridge)
        bridge.start_background_drain()

        admin = ManagedProcess("sdk-admin", [str(admin_bin), "interactive", "start",
            "--storage-directory", str(admin_state),
            "--local-server-port", str(SDK_ADMIN_RPC_PORT),
            "--fabric-bridge-server-port", str(SDK_BRIDGE_RPC_PORT),
            "--commissioner-vendor-id", "0xFFF1"], admin_state, logs)
        processes.append(admin)
        # The SDK can log immediately after its prompt on the same PTY line.
        admin.expect(r"^>>>[ \t]*", 90)
        await_output(bridge, r"Connected to Fabric-Admin", 30)

        local = admin.command(f"fabricsync add-local-bridge {SDK_BRIDGE_NODE_ID} "
                              f"--setup-pin-code {SDK_BRIDGE_PIN} --local-port {SDK_BRIDGE_PORT}")
        admin.expect(r"Successfully paired local bridge device", 180, local)
        print("PASS: official FabricAdmin commissioned its local SDK bridge", flush=True)

        crystal_env = os.environ.copy()
        crystal_env.update(MATTER_REVERSE_CONTROLLER_STATE=str(source_state),
                           MATTER_REVERSE_TEST_CONSENT="1",
                           MATTER_REVERSE_IP_ADDRESS=args.crystal_ip,
                           MATTER_REVERSE_PORT=str(CRYSTAL_PORT))
        aggregator = ManagedProcess("crystal-aggregator",
            [str(args.aggregator), "--no-interactive"], crystal_state, logs, crystal_env)
        processes.append(aggregator)
        aggregator.expect(r"Starting in Commissioning Mode", 60)
        code = aggregator.expect(r"chip-tool pairing code 1 ([\d-]+)", 20).group(1)
        aggregator.start_background_drain()

        command([str(args.driver), "commission-aggregator", str(source_state), code],
                logs / "source-commission.log", timeout=240)
        await_output(aggregator, r"Starting in Operational Mode", 30)
        print("PASS: Crystal Aggregator joined its private source fabric", flush=True)

        opened = command([str(args.driver), "open-aggregator-window", str(source_state)],
                         logs / "source-open-window.log", timeout=180)
        window_pin = re.search(r"Enhanced window PIN=(\d+)", opened)
        if window_pin is None:
            raise RuntimeError("Crystal source controller did not return an enhanced-window PIN")

        bridge_log_start = len(bridge.output)
        remote = admin.command(f"fabricsync add-bridge {CRYSTAL_NODE_ID} {window_pin.group(1)} "
                               f"{args.crystal_ip} {CRYSTAL_PORT}")
        admin.expect(r"Successfully paired bridge device", 180, remote)
        admin.start_background_drain()
        await_output(admin, r"Handle ReverseOpenCommissioningWindow command", 180, remote)
        await_output(bridge, r"Commissioning window is now open", 180, bridge_log_start)
        await_output(aggregator, r"Reverse commissioning complete", 180)
        print("PASS: SDK FabricAdmin opened its SDK bridge after Crystal's real response", flush=True)

        command([str(args.driver), "verify", str(source_state)],
                logs / "source-case-verify.log", timeout=240)
        print(f"PASS: Crystal Aggregator and official SDK bridge each have two fabrics and CASE; logs: {logs}",
              flush=True)
    finally:
        for process in reversed(processes):
            process.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--aggregator", type=Path, required=True)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--crystal-ip", default="fd42:4d41:5454::2")
    args = parser.parse_args()
    try:
        run(args)
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
