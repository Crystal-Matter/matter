#!/usr/bin/env python3
"""Run the official Matter 1.6 TC_OPCREDS_3_8 against a fresh Crystal JFA."""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

from sdk_jfc_switch_smoke import ManagedProcess, SETUP_PIN_PATTERN


TEST_NAME = "TC_OPCREDS_3_8"
REQUIRED_STEPS = ("19", "28")


def assert_official_result(output, returncode):
    if returncode:
        raise RuntimeError(f"official {TEST_NAME} exited {returncode}:\n{output[-12000:]}")
    if not re.search(r"Starting test from .*test_TC_OPCREDS_3_8", output):
        raise RuntimeError("official TC_OPCREDS_3_8 did not execute")
    for step in REQUIRED_STEPS:
        if not re.search(rf"Test Step {step}(?!\d)", output):
            raise RuntimeError(f"official TC_OPCREDS_3_8 omitted step {step}")
    if "Final result: PASS" not in output:
        raise RuntimeError("official TC_OPCREDS_3_8 did not report PASS")


def run(args):
    sdk = args.sdk.resolve()
    device = args.jfa.resolve()
    python = sdk / "out/python_env/bin/python3"
    test = sdk / "src/python_testing/TC_OPCREDS_3_8.py"
    for path in (device, python, test):
        if not path.is_file():
            raise RuntimeError(f"missing official test prerequisite: {path}")

    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    private = logs.parent / "interop-opcreds-vid-private"
    private.mkdir(parents=True, exist_ok=True)
    state = private / "crystal-jfa-state"
    state.mkdir(exist_ok=True)
    pics = logs / "pics-values"
    # The pinned SDK ci-pics file marks C0c as Tx. This test's PICS selector
    # requires Rsp; without it, the official test may report a skipped pass.
    pics.write_text("PICS_SDK_CI_ONLY=0\nOPCREDS.S=1\nOPCREDS.S.C0c.Rsp=1\n")

    process = ManagedProcess("crystal-jfa", [str(device), "--no-interactive"], state, logs)
    try:
        pin = process.expect(SETUP_PIN_PATTERN, 60).group(1)
        discriminator = process.expect(r"Discriminator:\s*(\d+)", 20).group(1)
        process.expect(r"Starting in Commissioning Mode", 60)
        process.start_background_drain()
        command = [
            str(python), str(test),
            "--commissioning-method", "on-network",
            "--dut-node-id", "1",
            "--passcode", pin,
            "--discriminator", discriminator,
            "--endpoint", "0",
            "--storage-path", str(private / "sdk-controller-storage.json"),
            "--logs-path", str(logs / "official-test-logs"),
            "--PICS", str(pics),
            "--fail-on-skipped",
        ]
        log = logs / "TC_OPCREDS_3_8.log"
        with log.open("wb") as output:
            result = subprocess.run(command, cwd=sdk, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=1200,
                                    env=os.environ.copy(), check=False)
        process.drain(0)
        assert_official_result(log.read_text(errors="replace"), result.returncode)
        print("PASS: unmodified Matter 1.6 TC_OPCREDS_3_8, steps 0-28, against Crystal JFA", flush=True)
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
