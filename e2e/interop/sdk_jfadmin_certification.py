#!/usr/bin/env python3
"""Run the unmodified Matter 1.6 TC_JFADMIN_1_2 against a Crystal JFA.

The SDK Python controller and Crystal device share one Linux network namespace.
The official test commissions the device itself, so no other commissioner is
allowed to touch the fresh device state before the test starts.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

from sdk_jfc_switch_smoke import ManagedProcess


def run(args):
    sdk = args.sdk.resolve()
    device = args.jfa.resolve()
    python = (sdk / "out/python_env/bin/python3").resolve()
    test = sdk / "src/python_testing/TC_JFADMIN_1_2.py"
    for executable in (device, python, test):
        if not executable.is_file():
            raise RuntimeError(f"missing official test prerequisite: {executable}")

    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    state = logs / "crystal-jfa-state"
    state.mkdir(exist_ok=True)
    pics = logs / "joint-fabric-pics-values"
    pics.write_text("PICS_SDK_CI_ONLY=0\nJFADMIN.S=1\n")

    process = ManagedProcess("crystal-jfa", [str(device), "--no-interactive"], state, logs)
    try:
        pin = process.expect(r"Setup PIN:\s*(\d{8})", 60).group(1)
        discriminator = process.expect(r"Discriminator:\s*(\d+)", 20).group(1)
        process.expect(r"Starting in Commissioning Mode", 60)
        command = [
            str(python), str(test),
            "--dut-node-id", "1",
            "--passcode", pin,
            "--discriminator", discriminator,
            "--storage-path", str(logs / "sdk-controller-storage.json"),
            "--logs-path", str(logs / "official-test-logs"),
            "--PICS", str(pics),
            "--string-arg", f"jfa_server_app:{device}",
        ]
        with (logs / "TC_JFADMIN_1_2.log").open("wb") as output:
            result = subprocess.run(command, cwd=sdk, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=300,
                                    env=os.environ.copy(), check=False)
        process.drain(0)
        if result.returncode:
            tail = (logs / "TC_JFADMIN_1_2.log").read_text(errors="replace")[-12000:]
            raise RuntimeError(f"official TC_JFADMIN_1_2 failed with exit {result.returncode}:\n{tail}")
        print("PASS: unmodified Matter 1.6 TC_JFADMIN_1_2 against Crystal JFA", flush=True)
    finally:
        process.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--jfa", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
