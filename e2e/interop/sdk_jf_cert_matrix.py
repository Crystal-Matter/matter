#!/usr/bin/env python3
"""Run unmodified Matter 1.6 Joint Fabric certification cases against Crystal JFA.

Each case gets fresh device, RPC bridge, controller, and persistence state. The
official SDK test owns commissioning and all protocol assertions.
"""

import argparse
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

from sdk_jfc_switch_smoke import ManagedProcess


CASES = ("TC_JFADMIN_1_1", "TC_JFDS_2_1")
RPC_PORT = 33033
SETUP_PIN_PATTERN = r"Setup PIN:\s*(\d{7,8})"


def await_bridge(process, port=RPC_PORT, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"RPC bridge exited with {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("RPC bridge did not listen")


def run_case(sdk, jfa, logs, name):
    python = sdk / "out/python_env/bin/python3"
    script = sdk / "src/python_testing" / f"{name}.py"
    jfc = sdk / "objdir-jf/linux-x64-jf-control-app-ipv6only-no-ble-no-wifi-clang/jfc-app"
    for path in (python, script, jfc, jfa):
        if not path.is_file():
            raise RuntimeError(f"missing official test prerequisite: {path}")

    case_logs = logs / name
    case_logs.mkdir(parents=True, exist_ok=True)
    state = case_logs / "crystal-state"
    state.mkdir(exist_ok=True)
    pics = case_logs / "pics-values"
    pics.write_text("PICS_SDK_CI_ONLY=0\nJFADMIN.S=1\nJFADMIN.S.A0000=1\nJFDS.S=1\n")

    device = None
    bridge = None
    bridge_log = None
    drain_thread = None
    stop_drain = threading.Event()
    try:
        device = ManagedProcess("crystal-jfa", [str(jfa), "--no-interactive"], state, case_logs)
        pin = device.expect(SETUP_PIN_PATTERN, 60).group(1)
        discriminator = device.expect(r"Discriminator:\s*(\d+)", 20).group(1)
        device.expect(r"Starting in Commissioning Mode", 60)
        def drain_device():
            while not stop_drain.is_set():
                device.drain(0.2)

        drain_thread = threading.Thread(target=drain_device, name="jfa-log-drain", daemon=True)
        drain_thread.start()

        bridge_log = (case_logs / "rpc-bridge.log").open("wb")
        bridge = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("joint_fabric_rpc_bridge.py")),
             "--host", "127.0.0.1", "--port", str(RPC_PORT)],
            stdout=bridge_log, stderr=subprocess.STDOUT, start_new_session=True,
        )
        await_bridge(bridge)

        command = [
            str(python), str(script),
            "--dut-node-id", "1",
            "--passcode", pin,
            "--discriminator", discriminator,
            "--storage-path", str(case_logs / "sdk-controller-storage.json"),
            "--logs-path", str(case_logs / "official-test-logs"),
            "--PICS", str(pics),
            "--string-arg", f"jfc_server_app:{jfc}",
            "--string-arg", f"jfa_server_app:{jfa}",
            "--string-arg", "dut_rpc_server_ip:127.0.0.1",
            "--string-arg", f"dut_rpc_server_port:{RPC_PORT}",
        ]
        with (case_logs / "official-test.log").open("wb") as output:
            result = subprocess.run(command, cwd=sdk, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=420, check=False,
                                    env=os.environ.copy())
        if result.returncode:
            tail = (case_logs / "official-test.log").read_text(errors="replace")[-14000:]
            raise RuntimeError(f"official {name} failed with exit {result.returncode}:\n{tail}")
        print(f"PASS: official Matter 1.6 {name} against Crystal JFA", flush=True)
    finally:
        stop_drain.set()
        if drain_thread is not None:
            drain_thread.join(timeout=2)
        if device is not None:
            device.close()
        if bridge is not None:
            bridge.terminate()
            try:
                bridge.wait(timeout=5)
            except subprocess.TimeoutExpired:
                bridge.kill()
                bridge.wait(timeout=5)
        if bridge_log is not None:
            bridge_log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--jfa", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--case", choices=CASES, action="append")
    args = parser.parse_args()
    try:
        for name in args.case or CASES:
            run_case(args.sdk.resolve(), args.jfa.resolve(), args.log_dir.resolve(), name)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
