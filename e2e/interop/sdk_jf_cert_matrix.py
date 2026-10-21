#!/usr/bin/env python3
"""Run unmodified Matter 1.6 Joint Fabric certification cases against Crystal JFA.

Each case gets fresh device, RPC bridge, controller, and persistence state. The
official SDK test owns commissioning and all protocol assertions.
"""

import argparse
import base64
import os
import socket
import subprocess
import sys
import threading
import time
from configparser import ConfigParser
from pathlib import Path

from sdk_jfc_switch_smoke import ManagedProcess


CASES = (
    "TC_JFADMIN_1_1",
    "TC_JFDS_2_1",
    "TC_JFDS_2_2",
    "TC_JFDS_2_3",
    "TC_JFDS_2_4",
    "TC_JFADMIN_1_4",
)
RPC_PORT = 33033
SETUP_PIN_PATTERN = r"Setup PIN:\s*(\d{7,8})"
DEFAULT_JF_FABRIC_ID = 1
P256_SERIALIZED_KEYPAIR_LENGTH = 97
P256_PUBLIC_KEY_LENGTH = 65


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


def start_bridge(case_logs, extra_args=()):
    bridge_log = (case_logs / "rpc-bridge.log").open("ab")
    bridge = subprocess.Popen(
        [sys.executable, str(Path(__file__).with_name("joint_fabric_rpc_bridge.py")),
         "--host", "127.0.0.1", "--port", str(RPC_PORT), *extra_args],
        stdout=bridge_log, stderr=subprocess.STDOUT, start_new_session=True,
    )
    try:
        await_bridge(bridge)
    except BaseException:
        close_bridge(bridge, bridge_log)
        raise
    return bridge, bridge_log


def close_bridge(bridge, bridge_log):
    bridge.terminate()
    try:
        bridge.wait(timeout=5)
    except subprocess.TimeoutExpired:
        bridge.kill()
        bridge.wait(timeout=5)
    bridge_log.close()


def preseed_sdk_issuer(jfc, storage_dir, case_logs):
    """Initialize a JFC commissioner so the official test reuses its issuer keys."""
    config_path = storage_dir / "chip_tool_config.alpha.ini"
    bridge, bridge_log = start_bridge(case_logs)
    try:
        preflight = ManagedProcess(
            "sdk-jfc-preflight",
            [str(jfc), "--rpc-server-port", str(RPC_PORT),
             "--storage-directory", str(storage_dir),
             "--commissioner-vendor-id", "0xFFF1"],
            storage_dir, case_logs,
        )
        try:
            preflight.expect(r">>>", 90)
            # JFC creates the issuer in InitializeCommissioner, which happens
            # only after dispatching a command. This unreachable pairing can
            # be interrupted once its issuer key is safely persisted.
            preflight.command("pairing onnetwork 1 20202021 --anchor true")
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                preflight.drain(0.2)
                config = ConfigParser()
                if config.read(config_path) and config.has_option("Default", "ExampleOpCredsCAKey0"):
                    break
                if preflight.process.poll() is not None:
                    raise RuntimeError("SDK JFC exited before persisting its CA keypair")
            else:
                raise RuntimeError("SDK JFC did not persist its CA keypair after pairing")
        finally:
            preflight.close()
    finally:
        close_bridge(bridge, bridge_log)

    config = ConfigParser()
    if not config.read(config_path):
        raise RuntimeError("SDK JFC did not persist its CA keypair")
    serialized = base64.b64decode(config.get("Default", "ExampleOpCredsCAKey0"), validate=True)
    if len(serialized) != P256_SERIALIZED_KEYPAIR_LENGTH or serialized[0] != 0x04:
        raise RuntimeError("SDK JFC persisted an unexpected CA keypair encoding")
    return serialized[:P256_PUBLIC_KEY_LENGTH]


def run_case(sdk, jfa, logs, name):
    python = sdk / "out/python_env/bin/python3"
    script = sdk / "src/python_testing" / f"{name}.py"
    jfc = sdk / "objdir-jf/linux-x64-jf-control-app-ipv6only-no-ble-no-wifi-clang/jfc-app"
    for path in (python, script, jfc, jfa):
        if not path.is_file():
            raise RuntimeError(f"missing official test prerequisite: {path}")

    case_logs = logs / name
    case_logs.mkdir(parents=True, exist_ok=True)
    # The SDK INI store contains private issuer keys. Keep it outside the CI
    # artifact directory, which uploads all files under case_logs.
    issuer_dir = logs.parent / "interop-jf-cert-private" / name
    issuer_dir.mkdir(parents=True, exist_ok=True)
    state = case_logs / "crystal-state"
    state.mkdir(exist_ok=True)
    csr_mailbox = case_logs / "icac-csr.json"
    csr_mailbox.unlink(missing_ok=True)
    pics = case_logs / "pics-values"
    pics.write_text("PICS_SDK_CI_ONLY=0\nJFADMIN.S=1\nJFADMIN.S.A0000=1\nJFDS.S=1\n")

    device = None
    bridge = None
    bridge_log = None
    drain_thread = None
    stop_drain = threading.Event()
    try:
        root_public_key = preseed_sdk_issuer(jfc, issuer_dir, case_logs)
        bridge, bridge_log = start_bridge(case_logs, (
            "--csr-mailbox-path", str(csr_mailbox),
            "--fabric-id", str(DEFAULT_JF_FABRIC_ID),
            "--root-public-key-hex", root_public_key.hex(),
        ))

        previous_mailbox = os.environ.get("MATTER_JFA_ICAC_CSR_MAILBOX_PATH")
        previous_jcm_consent = os.environ.get("MATTER_JFA_ALLOW_JCM")
        os.environ["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = str(csr_mailbox)
        if name == "TC_JFADMIN_1_4":
            os.environ["MATTER_JFA_ALLOW_JCM"] = "1"
        try:
            device = ManagedProcess("crystal-jfa", [str(jfa), "--no-interactive"], state, case_logs)
        finally:
            if previous_mailbox is None:
                os.environ.pop("MATTER_JFA_ICAC_CSR_MAILBOX_PATH", None)
            else:
                os.environ["MATTER_JFA_ICAC_CSR_MAILBOX_PATH"] = previous_mailbox
            if previous_jcm_consent is None:
                os.environ.pop("MATTER_JFA_ALLOW_JCM", None)
            else:
                os.environ["MATTER_JFA_ALLOW_JCM"] = previous_jcm_consent
        pin = device.expect(SETUP_PIN_PATTERN, 60).group(1)
        discriminator = device.expect(r"Discriminator:\s*(\d+)", 20).group(1)
        device.expect(r"Starting in Commissioning Mode", 60)
        def drain_device():
            while not stop_drain.is_set():
                device.drain(0.2)

        drain_thread = threading.Thread(target=drain_device, name="jfa-log-drain", daemon=True)
        drain_thread.start()

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
            "--string-arg", f"fabric_a_storage:{issuer_dir}",
            "--string-arg", "dut_rpc_server_ip:127.0.0.1",
            "--string-arg", f"dut_rpc_server_port:{RPC_PORT}",
        ]
        timeout = 760 if name == "TC_JFADMIN_1_4" else 420
        with (case_logs / "official-test.log").open("wb") as output:
            result = subprocess.run(command, cwd=sdk, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=timeout, check=False,
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
            close_bridge(bridge, bridge_log)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--jfa", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--case", choices=CASES, action="append")
    args = parser.parse_args()
    failures = []
    for name in args.case or CASES:
        try:
            run_case(args.sdk.resolve(), args.jfa.resolve(), args.log_dir.resolve(), name)
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            failures.append(name)
            print(f"FAIL {name}: {error}", file=sys.stderr, flush=True)
    if failures:
        print(f"Failed official cases: {', '.join(failures)}", file=sys.stderr)
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
