#!/usr/bin/env python3
"""Run SDK 1.6 VVS-bearing JFA against Crystal Anchor JCM in GitHub CI."""

import argparse
import os
import signal
import socket
import ssl
import subprocess
import sys
import time
from pathlib import Path

from sdk_jfc_switch_smoke import ManagedProcess, SETUP_PIN_PATTERN
from sdk_jfc_jcm_live import run_command


SDK_IPV6_HOST = "fd42:4d41:5454::2"


def await_dcl(process, certificate):
    context = ssl.create_default_context(cafile=str(certificate))
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"test DCL mirror exited: {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", 443), timeout=0.5) as connection:
                with context.wrap_socket(connection, server_hostname="127.0.0.1"):
                    return
        except (OSError, ssl.SSLError):
            time.sleep(0.1)
    raise RuntimeError("test DCL TLS listener did not become ready")


def run(args):
    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    private = logs.parent / "sdk-jfa-vvs-private"
    private.mkdir(parents=True, exist_ok=True)
    private.chmod(0o700)
    sdk = args.sdk.resolve()
    jfa = args.jfa.resolve()
    driver = args.driver.resolve()
    python = sdk / "out/python_env/bin/python3"
    jfc = sdk / "objdir-jf/linux-x64-jf-control-app-ipv6only-no-ble-no-wifi-clang/jfc-app"
    sdk_jfa = sdk / "objdir-jf/linux-x64-jf-admin-app-ipv6only-no-ble-no-wifi-clang/jfa-app"
    script = Path(__file__).with_name("TC_SDK_JFA_VVS.py").resolve()
    for binary in (python, jfc, sdk_jfa, jfa, driver):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError(f"missing executable: {binary}")

    bootstrap = private / "a-bootstrap.yml"
    a_root = private / "a-root.tlv"
    b_root = private / "unused-b-root.tlv"
    a_exchange = private / "a-jcm-rpc.yml"
    a_command = private / "a-command.yml"
    a_discovery_gate = private / "allow-crystal-a-discovery"
    cross_icac = private / "cross-icac.tlv"
    dcl_state = private / "dcl-state.json"
    dcl_cert = private / "dcl-tls-cert.pem"
    dcl_key = private / "dcl-tls-key.pem"
    for path in (bootstrap, a_root, b_root, a_exchange, a_command, a_discovery_gate,
                 cross_icac, dcl_state, dcl_cert, dcl_key):
        path.unlink(missing_ok=True)
    run_command([str(driver), "setup", str(bootstrap), str(a_root)],
                logs / "a-setup.log")
    # The Crystal driver selects the live DCL source; this argument is unused
    # in that mode but remains required by its generic commissioning CLI.
    b_root.write_bytes(b"")
    run_command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256",
                 "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
                 "-addext", "subjectAltName=IP:127.0.0.1",
                 "-addext", "basicConstraints=critical,CA:TRUE",
                 "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
                 "-keyout", str(dcl_key), "-out", str(dcl_cert)],
                logs / "dcl-tls-certificate.log")
    dcl_key.chmod(0o600)

    dcl_log = (logs / "dcl-mirror.log").open("wb")
    dcl = subprocess.Popen(["sudo", "-n", sys.executable,
                            str(Path(__file__).with_name("jfa_vvs_dcl_mirror.py")),
                            "--state", str(dcl_state), "--cert", str(dcl_cert),
                            "--key", str(dcl_key)],
                           stdout=dcl_log, stderr=subprocess.STDOUT,
                           start_new_session=True)
    a = None
    try:
        await_dcl(dcl, dcl_cert)
        a_state = private / "crystal-a"
        a_state.mkdir(exist_ok=True)
        a_env = os.environ.copy()
        a_env.update(MATTER_JFA_PORT="5540", MATTER_JFA_PROVISIONED_ANCHOR="1",
                     MATTER_JFA_ALLOW_JCM="1",
                     MATTER_JFA_BOOTSTRAP_STATE_PATH=str(bootstrap),
                     MATTER_JFA_DISCOVERY_GATE_PATH=str(a_discovery_gate),
                     MATTER_JFA_COMMAND_PATH=str(a_command),
                     MATTER_JFA_JCM_REQUEST_PATH=str(a_exchange),
                     MATTER_JFA_DCL_GATEWAY_URL="https://127.0.0.1",
                     MATTER_JFA_VID_TRUST_ROOT_PATH=str(a_root),
                     SSL_CERT_FILE=str(dcl_cert),
                     MATTER_JFA_ANCHOR_OPERATIONAL_PORT="5541",
                     MATTER_JFA_TRANSFER_PEERS=f"a103={SDK_IPV6_HOST}")
        a = ManagedProcess("crystal-a", [str(jfa), "--no-interactive"],
                           a_state, logs, a_env)
        pin = a.expect(SETUP_PIN_PATTERN, 60).group(1)
        discriminator = a.expect(r"Discriminator:\s*(\d+)", 10).group(1)
        a.expect(r"Starting in Commissioning Mode", 60)
        a_code = a.expect(r"chip-tool pairing code 1 ([\d-]+)", 20).group(1)
        a.start_background_drain()

        pics = logs / "pics-values"
        pics.write_text("PICS_SDK_CI_ONLY=0\nJFADMIN.S=1\nJFADMIN.S.A0000=1\n")
        fields = {
            "vvs_logs": logs,
            "vvs_sdk_store": private / "sdk-b",
            "vvs_dcl_state": dcl_state,
            "vvs_sdk_jfa": sdk_jfa,
            "vvs_sdk_jfc": jfc,
            "vvs_sdk_root": sdk,
            "vvs_driver": driver,
            "vvs_tls_cert": dcl_cert,
            "vvs_bootstrap": bootstrap,
            "vvs_a_code": a_code,
            "vvs_b_root": b_root,
            "vvs_a_exchange": a_exchange,
            "vvs_a_command": a_command,
            "vvs_a_discovery_gate": a_discovery_gate,
            "vvs_cross_icac": cross_icac,
            "vvs_sdk_ipv6_host": SDK_IPV6_HOST,
        }
        command = [str(python), str(script), "--dut-node-id", "1", "--passcode", pin,
                   "--discriminator", discriminator,
                   "--storage-path", str(private / "sdk-controller-storage.json"),
                   "--logs-path", str(logs / "sdk-python-logs"),
                   "--paa-trust-store-path", str(sdk / "credentials/development/paa-root-certs"),
                   "--PICS", str(pics)]
        for key, value in fields.items():
            command.extend(("--string-arg", f"{key}:{value}"))
        official_log = logs / "sdk-vvs-case.log"
        with official_log.open("wb") as output:
            result = subprocess.run(command, cwd=sdk, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=1500,
                                    check=False, env=os.environ.copy())
        if result.returncode:
            raise RuntimeError(f"SDK VVS JFA fixture failed ({result.returncode}):\n" +
                               official_log.read_text(errors="replace")[-14000:])
        print(f"PASS: independent SDK VVS JFA joined Crystal Anchor; logs: {logs}", flush=True)
    finally:
        if a is not None:
            a.close()
        if dcl.poll() is None:
            os.killpg(dcl.pid, signal.SIGTERM)
            try:
                dcl.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(dcl.pid, signal.SIGKILL)
                dcl.wait(timeout=5)
        dcl_log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--jfa", type=Path, required=True)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args)
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
