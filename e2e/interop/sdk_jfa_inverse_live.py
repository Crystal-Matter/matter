#!/usr/bin/env python3
"""Crystal controller -> official Matter 1.6 JFA Anchor CASE smoke.

Run after sdk_jfc_switch_smoke.py so the expensive SDK build is reused. This
test starts a fresh SDK JFA because the first scenario has already paired its
JFA to the official JFC's fabric. The Crystal controller owns its Anchor CA.
"""

import argparse
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from sdk_jfc_switch_smoke import ManagedProcess


def run(args):
    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    sdk = args.sdk.resolve()
    jfa_bin = sdk / "objdir-jf/linux-x64-jf-admin-app-ipv6only-no-ble-no-wifi-clang/jfa-app"
    driver = args.driver.resolve()
    for binary in (jfa_bin, driver):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError(f"missing executable: {binary}")

    run_id = uuid.uuid4().hex[:8]
    # Both KVS and Crystal controller state contain private operational keys.
    # Fresh state is essential for a repeat run to commission a fresh fabric.
    with tempfile.TemporaryDirectory(prefix="matter-sdk-jfa-inverse-") as private_dir:
        state = Path(private_dir)
        kvs = state / "kvs"
        kvs.touch()
        jfa = ManagedProcess(
            f"inverse-jfa-{run_id}",
            [str(jfa_bin), "--capabilities", "0x4", "--passcode", "11022033",
             "--discriminator", "3840", "--secured-device-port", "5533",
             "--rpc-server-port", "33033", "--KVS", str(kvs)],
            state, logs,
        )
        try:
            jfa.start_background_drain()
            time.sleep(3)
            if jfa.process.poll() is not None:
                raise RuntimeError("official JFA exited before Crystal commissioning")
            private_state = state / "controller-state.yml"
            driver_log = logs / f"inverse-driver-{run_id}.log"
            with driver_log.open("wb") as output:
                try:
                    result = subprocess.run(
                        [str(driver), str(private_state), args.ipv6_address],
                        cwd=state, stdout=output, stderr=subprocess.STDOUT,
                        timeout=300, check=False,
                    )
                except subprocess.TimeoutExpired as error:
                    raise RuntimeError("Crystal -> SDK JFA CASE driver timed out") from error
            transcript = driver_log.read_text(errors="replace")
            if result.returncode != 0 or "PASS: Crystal CASE read official SDK JFA and Datastore Anchor identity" not in transcript:
                raise RuntimeError(
                    f"Crystal -> SDK JFA CASE driver exited {result.returncode}; "
                    f"log tail:\n{transcript[-5000:]}"
                )
            print(f"PASS: Crystal controller commissioned official SDK JFA and read JFA/Datastore over CASE; logs: {logs}")
        finally:
            jfa.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--ipv6-address", default="fd42:4d41:5454::2")
    args = parser.parse_args()
    try:
        run(args)
    except (OSError, RuntimeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
