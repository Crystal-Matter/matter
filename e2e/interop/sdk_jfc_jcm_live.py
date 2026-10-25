#!/usr/bin/env python3
"""Live Matter 1.6 JFC -> Crystal JFA CSR and two-JFA JCM interoperability.

Runs in one Linux network namespace with Avahi. Each assertion is mandatory;
logs are retained when a protocol step fails.
"""

import argparse
import base64
import json
import os
import signal
import socket
import ssl
import subprocess
import sys
import time
import urllib.request
import uuid
from pathlib import Path

import yaml

from sdk_jfc_switch_smoke import ManagedProcess, SETUP_PIN_PATTERN, JFC_PROMPT_PATTERN
from sdk_jfc_dcl_mirror import sdk_public_root_der


def run_command(argv, log_path, timeout=300, env=None):
    with log_path.open("wb") as output:
        result = subprocess.run(argv, stdout=output, stderr=subprocess.STDOUT,
                                timeout=timeout, check=False, env=env)
    if result.returncode:
        raise RuntimeError(f"command exited {result.returncode}: {' '.join(map(str, argv))}; "
                           f"log tail:\n{log_path.read_text(errors='replace')[-5000:]}")


def write_dcl_state(path, mode, certificate):
    temporary = path.with_suffix(".next")
    temporary.write_text(json.dumps({"mode": mode,
                                     "root_der": base64.b64encode(certificate).decode()}))
    temporary.replace(path)


def await_test_dcl(process, certificate, timeout=15):
    context = ssl.create_default_context(cafile=str(certificate))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"test DCL mirror exited: {process.returncode}")
        try:
            with urllib.request.urlopen(
                    "https://127.0.0.1/dcl/pki/noc-vid-root-certificates/65521",
                    context=context, timeout=1) as response:
                if response.status == 200:
                    return
        except (OSError, ssl.SSLError):
            time.sleep(0.1)
    raise RuntimeError("test HTTPS DCL mirror did not become ready")


def await_bridge(port, process):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"CSR bridge exited: {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("CSR bridge did not listen")


def inspect_identity(path, timeout=20):
    path.unlink(missing_ok=True)
    nonce = uuid.uuid4().hex
    path.write_text(yaml.safe_dump({"jfa_command": {"request": {
        "operation": "inspect-anchor-identity", "node_id": 0, "nonce": nonce,
        "interrupt_after_remove_fabric": False, "jcm": False,
    }}}))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = yaml.safe_load(path.read_text()) or {}
        result = data.get("jfa_command", {}).get("result", {})
        if result.get("nonce") == nonce and result.get("status") not in (None, "in-progress"):
            if result.get("status") != "ok" or result.get("fabric_present") is not True:
                raise RuntimeError(f"JFA identity probe failed: {result}")
            required = ("inspected_fabric_id", "inspected_root_public_key",
                        "inspected_root_certificate", "inspected_icac_certificate",
                        "inspected_node_id")
            if any(result.get(field) is None for field in required):
                raise RuntimeError(f"JFA identity probe omitted {required}: {result}")
            return result
        time.sleep(0.1)
    raise RuntimeError("JFA identity probe timed out")


def run(args):
    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    sdk = args.sdk.resolve()
    jfc_bin = sdk / "objdir-jf/linux-x64-jf-control-app-ipv6only-no-ble-no-wifi-clang/jfc-app"
    for binary in (jfc_bin, args.jfa, args.driver):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError(f"missing executable: {binary}")

    a_state = logs / "a-state"
    b_state = logs / "b-state"
    jfc_state = logs / "jfc-state"
    for directory in (a_state, b_state, jfc_state):
        directory.mkdir(exist_ok=True)
    bootstrap = logs / "a-bootstrap.yml"
    a_root = logs / "a-root.tlv"
    b_root = logs / "b-root.tlv"
    b_command = logs / "b-command.yml"
    a_command = logs / "a-command.yml"
    a_exchange = logs / "a-jcm-rpc.yml"
    csr_mailbox = logs / "b-icac-csr.json"
    cross_icac = logs / "cross-signed-icac.tlv"
    for path in (bootstrap, a_root, b_root, b_command, a_command,
                 a_exchange, csr_mailbox, cross_icac):
        path.unlink(missing_ok=True)
    run_command([str(args.driver), "setup", str(bootstrap), str(a_root)],
                logs / "a-setup.log")

    processes = []
    bridge = None
    bridge_log = None
    dcl = None
    dcl_log = None
    try:
        b_env = os.environ.copy()
        b_env.update(MATTER_JFA_PORT="5541", MATTER_JFA_PROVISIONED_ANCHOR="1",
                     MATTER_JFA_ALLOW_JCM="1", MATTER_JFA_COMMAND_PATH=str(b_command),
                     MATTER_JFA_ICAC_CSR_MAILBOX_PATH=str(csr_mailbox),
                     MATTER_JFA_VID_TRUST_ROOT_PATH=str(a_root),
                     MATTER_JFA_ANCHOR_OPERATIONAL_PORT="5540")
        b = ManagedProcess("crystal-b", [str(args.jfa), "--no-interactive"], b_state, logs, b_env)
        processes.append(b)
        b_pin = b.expect(SETUP_PIN_PATTERN, 60).group(1)
        b_discriminator = b.expect(r"Discriminator:\s*(\d+)", 10).group(1)
        b.expect(r"Starting in Commissioning Mode", 60)
        b.start_background_drain()

        bridge_log = (logs / "csr-bridge.log").open("wb")
        bridge = subprocess.Popen([sys.executable,
            str(Path(__file__).with_name("joint_fabric_rpc_bridge.py")),
            "--host", "127.0.0.1", "--port", "33033",
            "--csr-mailbox-path", str(csr_mailbox)],
            stdout=bridge_log, stderr=subprocess.STDOUT, start_new_session=True)
        await_bridge(33033, bridge)

        jfc = ManagedProcess("sdk-jfc", [str(jfc_bin), "--rpc-server-port", "33033",
            "--storage-directory", str(jfc_state), "--commissioner-vendor-id", "0xFFF1"],
            jfc_state, logs)
        processes.append(jfc)
        jfc.expect(JFC_PROMPT_PATTERN, 90)
        paired = jfc.command(f"pairing onnetwork-long 11 {b_pin} {b_discriminator} --anchor true")
        jfc.expect(r"Anchor Administrator \(nodeId=11\) commissioned with success", 180, paired)
        jfc.expect(JFC_PROMPT_PATTERN, 30, paired)
        b_identity = inspect_identity(b_command)
        if b_identity["inspected_node_id"] != 11:
            raise RuntimeError("SDK JFC commissioned an unexpected B Anchor Node ID")
        b_root.write_bytes(b_identity["inspected_root_certificate"])
        print("PASS: SDK JFC commissioned Crystal B JFA as Anchor", flush=True)

        # Publish only the SDK-owned issuer's public X.509 root. The mirror is
        # an isolated test server, not a substitute for a synchronized DCL.
        root_der = sdk_public_root_der(jfc_state)
        dcl_state = logs / "test-dcl-state.json"
        dcl_cert = logs / "test-dcl-cert.pem"
        dcl_key = logs / "test-dcl-key.pem"
        run_command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256",
                     "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
                     "-addext", "subjectAltName=IP:127.0.0.1",
                     "-addext", "basicConstraints=critical,CA:TRUE",
                     "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
                     "-keyout", str(dcl_key), "-out", str(dcl_cert)],
                    logs / "test-dcl-certificate.log")
        write_dcl_state(dcl_state, "active", root_der)
        dcl_log = (logs / "test-dcl-mirror.log").open("wb")
        dcl = subprocess.Popen(["sudo", "-n", sys.executable,
            str(Path(__file__).with_name("sdk_jfc_dcl_mirror.py")),
            "--state", str(dcl_state), "--cert", str(dcl_cert), "--key", str(dcl_key)],
            stdout=dcl_log, stderr=subprocess.STDOUT, start_new_session=True)
        await_test_dcl(dcl, dcl_cert)
        crystal_dcl_env = os.environ.copy()
        crystal_dcl_env.update(SSL_CERT_FILE=str(dcl_cert),
                               MATTER_JCM_TEST_DCL_GATEWAY_URL="https://127.0.0.1")

        identity_json = logs / "b-identity.json"
        identity_json.write_text(json.dumps({
            "icac_certificate": base64.b64encode(b_identity["inspected_icac_certificate"]).decode(),
        }))

        a_env = os.environ.copy()
        a_env.update(MATTER_JFA_PORT="5540", MATTER_JFA_PROVISIONED_ANCHOR="1",
                     MATTER_JFA_BOOTSTRAP_STATE_PATH=str(bootstrap),
                     MATTER_JFA_COMMAND_PATH=str(a_command),
                     MATTER_JFA_JCM_REQUEST_PATH=str(a_exchange),
                     MATTER_JFA_DCL_GATEWAY_URL="https://127.0.0.1",
                     SSL_CERT_FILE=str(dcl_cert),
                     MATTER_JFA_ANCHOR_OPERATIONAL_PORT="5541",
                     MATTER_JFA_TRANSFER_PEERS="a103=127.0.0.1")
        a = ManagedProcess("crystal-a", [str(args.jfa), "--no-interactive"], a_state, logs, a_env)
        processes.append(a)
        a.expect(SETUP_PIN_PATTERN, 60)
        a.expect(r"Discriminator:\s*(\d+)", 10)
        a.expect(r"Starting in Commissioning Mode", 60)
        a_code = a.expect(r"chip-tool pairing code 1 ([\d-]+)", 20).group(1)
        a.start_background_drain()

        opened = jfc.command("pairing open-joint-commissioning-window 11 1 400 1000 1261")
        b_code = jfc.expect(r"Manual pairing code:\s*\[([^\]]+)\]", 90, opened).group(1)
        jfc.expect(JFC_PROMPT_PATTERN, 30, opened)
        print("PASS: SDK JFC opened B Joint Commissioning window", flush=True)

        before_denial_b = inspect_identity(b_command)
        if before_denial_b.get("inspected_fabric_count") != 1 or \
                before_denial_b.get("inspected_administrator_fabric_index") != 1:
            raise RuntimeError("B did not start Joint Commissioning on its original fabric")

        for mode, expected in (("wrong-vid", "deny"), ("removed", "deny"),
                               ("active", "accept")):
            write_dcl_state(dcl_state, mode, root_der)
            run_command([str(args.driver), "probe-dcl", b_code, "5541",
                         "https://127.0.0.1", expected],
                        logs / f"test-dcl-{mode}.log", timeout=90,
                        env=crystal_dcl_env)
        print("PASS: live SDK issuer root denied for wrong VID/removed DCL records and accepted when active", flush=True)

        denied_env = crystal_dcl_env.copy()
        denied_env["MATTER_JCM_TEST_CONSENT"] = "deny"
        run_command([str(args.driver), "commission", str(bootstrap), a_code, b_code,
                     str(b_root), str(a_exchange), str(a_command), str(cross_icac),
                     "5540", "5541"], logs / "crystal-jcm-consent-denied.log",
                    timeout=360, env=denied_env)
        after_denial_b = inspect_identity(b_command)
        after_denial_a = inspect_identity(a_command)
        for field in ("inspected_fabric_count", "inspected_administrator_fabric_index",
                      "inspected_cross_signed_icac"):
            if after_denial_b.get(field) != before_denial_b.get(field):
                raise RuntimeError(f"Consent denial changed B {field}")
        admins = after_denial_a.get("inspected_datastore_admin_entries")
        if admins is None or len(admins) != 1:
            raise RuntimeError("Consent denial registered a joining administrator in A Datastore")
        print("PASS: consent denial left B fabrics and A Datastore unchanged", flush=True)

        # The denied attempt armed the target fail-safe. Restarting the test
        # JFA rolls it back before the authorized attempt opens a fresh window.
        b.close()
        processes.remove(b)
        b = ManagedProcess("crystal-b-restarted", [str(args.jfa), "--no-interactive"],
                           b_state, logs, b_env)
        processes.append(b)
        b.expect(r"Starting in Operational Mode", 60)
        b.start_background_drain()
        reopened = jfc.command("pairing open-joint-commissioning-window 11 1 400 1000 1261")
        b_code = jfc.expect(r"Manual pairing code:\s*\[([^\]]+)\]", 90, reopened).group(1)
        jfc.expect(JFC_PROMPT_PATTERN, 30, reopened)

        allowed_env = crystal_dcl_env.copy()
        allowed_env["MATTER_JCM_TEST_SKIP_ANCHOR_COMMISSION"] = "1"
        run_command([str(args.driver), "commission", str(bootstrap), a_code, b_code,
                     str(b_root), str(a_exchange), str(a_command), str(cross_icac),
                     "5540", "5541"], logs / "crystal-jcm-driver.log", timeout=360,
                    env=allowed_env)
        print("PASS: Crystal A JCM received Anchor-originated CommissioningComplete and Datastore registration", flush=True)

        csr_result = json.loads(csr_mailbox.read_text())
        if csr_result.get("status") != "ok" or not csr_result.get("csr"):
            raise RuntimeError(f"SDK CSR exchange did not complete: {csr_result}")
        csr_path = logs / "sdk-icac.csr.der"
        csr_path.write_bytes(base64.b64decode(csr_result["csr"], validate=True))
        run_command([str(args.driver), "verify-csr", str(identity_json), str(csr_path)],
                    logs / "sdk-csr-verify.log")
        print("PASS: SDK GetStream/ResponseStream CSR signature matches commissioned B ICAC", flush=True)

        committed = inspect_identity(b_command)
        if committed.get("inspected_cross_signed_icac") != cross_icac.read_bytes():
            raise RuntimeError("Crystal B did not persist the A-signed cross-ICAC")
        if committed.get("inspected_administrator_fabric_index") != 2:
            raise RuntimeError("Crystal B did not switch AdministratorFabricIndex to A fabric")
        print(f"PASS: live SDK JFC ↔ Crystal JFA Joint Commissioning; logs: {logs}", flush=True)
    finally:
        for process in reversed(processes):
            process.close()
        if bridge is not None:
            bridge.terminate()
            try:
                bridge.wait(timeout=5)
            except subprocess.TimeoutExpired:
                bridge.kill()
                bridge.wait(timeout=5)
        if bridge_log is not None:
            bridge_log.close()
        if dcl is not None:
            if dcl.poll() is None:
                os.killpg(dcl.pid, signal.SIGTERM)
                try:
                    dcl.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(dcl.pid, signal.SIGKILL)
                    dcl.wait(timeout=5)
        if dcl_log is not None:
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
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
