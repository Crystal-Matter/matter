#!/usr/bin/env python3
"""Run unmodified Matter 1.6 multi-ecosystem JFA cases with a Crystal DUT.

The SDK test owns all Interaction Model assertions. This fixture supplies the
external Crystal JFA, its JFC RPC bridge, and isolated issuer stores.
"""

import argparse
import base64
import os
import socket
import subprocess
import sys
import time
from configparser import ConfigParser
from pathlib import Path

from sdk_jfc_switch_smoke import ManagedProcess, SETUP_PIN_PATTERN


RPC_PORT = 33033
P256_SERIALIZED_KEYPAIR_LENGTH = 97
P256_PUBLIC_KEY_LENGTH = 65
CASES = ("TC_JFADMIN_2_2",)


def await_bridge(process, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"RPC bridge exited with {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", RPC_PORT), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("RPC bridge did not listen")


def start_bridge(logs, *, csr_mailbox=None, fabric_id=None, root_public_key=None):
    command = [sys.executable, str(Path(__file__).with_name("joint_fabric_rpc_bridge.py")),
               "--host", "127.0.0.1", "--port", str(RPC_PORT)]
    if csr_mailbox is not None:
        command.extend(("--csr-mailbox-path", str(csr_mailbox), "--fabric-id", str(fabric_id),
                        "--root-public-key-hex", root_public_key.hex()))
    output = (logs / "rpc-bridge.log").open("ab")
    process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        await_bridge(process)
    except BaseException:
        stop_bridge(process, output)
        raise
    return process, output


def stop_bridge(process, output):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    output.close()


def preseed_sdk_issuer(jfc, storage_dir, logs, commissioner_name):
    """Persist the SDK JFC issuer before an official script reopens its store."""
    config_path = storage_dir / f"chip_tool_config.{commissioner_name}.ini"
    bridge, bridge_log = start_bridge(logs)
    try:
        preflight = ManagedProcess(
            f"sdk-jfc-{commissioner_name}-preflight",
            [str(jfc), "--rpc-server-port", str(RPC_PORT),
             "--storage-directory", str(storage_dir),
             "--commissioner-vendor-id", "0xFFF1"], storage_dir, logs)
        try:
            preflight.expect(r">>>\s*$", 90)
            # InitializeCommissioner creates and persists the issuer on the
            # first pairing command. The unreachable target is never paired.
            preflight.command(
                f"pairing onnetwork 1 20202021 --anchor true --commissioner-name {commissioner_name}")
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                preflight.drain(0.2)
                config = ConfigParser()
                if (config.read(config_path) and
                        config.has_option("Default", "ExampleOpCredsCAKey0") and
                        config.has_option("Default", "ExampleCARootCert0")):
                    break
                if preflight.process.poll() is not None:
                    raise RuntimeError("SDK JFC exited before persisting its CA keypair")
            else:
                raise RuntimeError(f"SDK JFC did not persist {commissioner_name} CA keypair")
        finally:
            preflight.close()
    finally:
        stop_bridge(bridge, bridge_log)

    config = ConfigParser()
    if not config.read(config_path):
        raise RuntimeError(f"SDK JFC {commissioner_name} issuer store is missing")
    serialized = base64.b64decode(config.get("Default", "ExampleOpCredsCAKey0"), validate=True)
    if len(serialized) != P256_SERIALIZED_KEYPAIR_LENGTH or serialized[0] != 0x04:
        raise RuntimeError("SDK JFC persisted an unexpected CA keypair encoding")
    root_certificate = base64.b64decode(config.get("Default", "ExampleCARootCert0"), validate=True)
    if not root_certificate:
        raise RuntimeError("SDK JFC did not persist a root certificate")
    return serialized[:P256_PUBLIC_KEY_LENGTH], root_certificate


def run_2_2(sdk, jfa, logs):
    name = "TC_JFADMIN_2_2"
    python = sdk / "out/python_env/bin/python3"
    script = sdk / "src/python_testing" / f"{name}.py"
    jfc = sdk / "objdir-jf/linux-x64-jf-control-app-ipv6only-no-ble-no-wifi-clang/jfc-app"
    sdk_jfa = sdk / "objdir-jf/linux-x64-jf-admin-app-ipv6only-no-ble-no-wifi-clang/jfa-app"
    server = sdk / "objdir-jf/linux-x64-all-clusters-ipv6only-no-ble-no-wifi-clang/chip-all-clusters-app"
    for path in (python, script, jfc, sdk_jfa, server, jfa):
        if not path.is_file():
            raise RuntimeError(f"missing official test prerequisite: {path}")

    case_logs = logs / name
    case_logs.mkdir(parents=True, exist_ok=True)
    private = logs.parent / "interop-jfadmin-multi-private" / name
    a_store = private / "sdk-a"
    b_store = private / "sdk-b"
    device_state = private / "crystal-b"
    for path in (a_store, b_store, device_state):
        path.mkdir(parents=True, exist_ok=True)

    _, a_root = preseed_sdk_issuer(jfc, a_store, case_logs, "alpha")
    b_root_public_key, _ = preseed_sdk_issuer(jfc, b_store, case_logs, "beta")
    a_root_path = private / "a-root.tlv"
    a_root_path.write_bytes(a_root)
    csr_mailbox = private / "b-icac-csr.json"
    csr_mailbox.unlink(missing_ok=True)
    bridge, bridge_log = start_bridge(case_logs, csr_mailbox=csr_mailbox,
                                      fabric_id=2, root_public_key=b_root_public_key)
    device = None
    try:
        env = os.environ.copy()
        env.update(MATTER_JFA_PORT="5541", MATTER_JFA_PROVISIONED_ANCHOR="1",
                   MATTER_JFA_ALLOW_JCM="1", MATTER_JFA_ICAC_CSR_MAILBOX_PATH=str(csr_mailbox),
                   MATTER_JFA_VID_TRUST_ROOT_PATH=str(a_root_path))
        device = ManagedProcess("crystal-b", [str(jfa), "--no-interactive"],
                                device_state, case_logs, env)
        pin = device.expect(SETUP_PIN_PATTERN, 60).group(1)
        discriminator = device.expect(r"Discriminator:\s*(\d+)", 20).group(1)
        device.expect(r"Starting in Commissioning Mode", 60)
        device.start_background_drain()

        pics = case_logs / "pics-values"
        pics.write_text("PICS_SDK_CI_ONLY=0\nJFADMIN.S=1\nJFADMIN.S.A0000=1\nJFDS.S=1\n")
        command = [
            str(python), str(script), "--dut-node-id", "11", "--passcode", pin,
            "--discriminator", discriminator,
            "--storage-path", str(private / "sdk-controller-storage.json"),
            "--logs-path", str(case_logs / "official-test-logs"),
            "--paa-trust-store-path", str(sdk / "credentials/development/paa-root-certs"),
            "--PICS", str(pics),
            "--string-arg", f"jfc_server_app:{jfc}",
            "--string-arg", f"jfa_server_app:{sdk_jfa}",
            "--string-arg", f"th_server_app:{server}",
            "--string-arg", f"fabric_a_storage:{a_store}",
            "--string-arg", f"fabric_b_storage:{b_store}",
            "--string-arg", "dut_rpc_server_ip:127.0.0.1",
            "--string-arg", f"dut_rpc_server_port:{RPC_PORT}",
        ]
        with (case_logs / "official-test.log").open("wb") as output:
            result = subprocess.run(command, cwd=sdk, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=900, check=False,
                                    env=os.environ.copy())
        if result.returncode:
            tail = (case_logs / "official-test.log").read_text(errors="replace")[-14000:]
            raise RuntimeError(f"official {name} failed with exit {result.returncode}:\n{tail}")
        print(f"PASS: official Matter 1.6 {name} against Crystal JFA", flush=True)
    finally:
        if device is not None:
            device.close()
        stop_bridge(bridge, bridge_log)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--jfa", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--case", choices=CASES, default="TC_JFADMIN_2_2")
    args = parser.parse_args()
    try:
        run_2_2(args.sdk.resolve(), args.jfa.resolve(), args.log_dir.resolve())
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
