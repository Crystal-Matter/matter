#!/usr/bin/env python3
"""Run Crystal VID/VVSC verification against a real matter.js device.

Requires a built matter.js 0.18.0 checkout and a compiled Crystal driver.
The device is independent; the HTTPS DCL records and signer are test fixtures.
"""

import argparse
import json
import os
from pathlib import Path
import re
import signal
import ssl
import subprocess
import sys
import time
import urllib.request


MATTER_JS_COMMIT = "7e1f5d7892dcea4330828b6a82d31ffe2a04cc0b"
PAIRING_PATTERN = re.compile(r"manual pairing code:\s*(\d+)")
GATEWAY = "https://127.0.0.1"


def run_command(argv, log, env=None, timeout=180):
    with log.open("wb") as output:
        result = subprocess.run(argv, stdout=output, stderr=subprocess.STDOUT,
                                env=env, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, argv))} exited {result.returncode}:\n"
                           + log.read_text(errors="replace")[-6000:])
    print(log.read_text(errors="replace")[-1000:].strip(), flush=True)


def await_pairing_code(process, output, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"matter.js device exited {process.returncode}:\n"
                               + output.read_text(errors="replace")[-6000:])
        match = PAIRING_PATTERN.search(output.read_text(errors="replace"))
        if match:
            return match.group(1)
        time.sleep(0.2)
    raise RuntimeError("matter.js pairing code did not appear")


def await_gateway(process, certificate, port, timeout=15):
    context = ssl.create_default_context(cafile=str(certificate))
    url = f"https://127.0.0.1:{port}/dcl/pki/noc-vid-root-certificates/65521"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"DCL fixture exited {process.returncode}")
        try:
            with urllib.request.urlopen(url, context=context, timeout=1) as response:
                if response.status == 200:
                    return
        except (OSError, ssl.SSLError):
            time.sleep(0.1)
    raise RuntimeError("HTTPS DCL fixture did not become ready")


def set_mode(path, mode):
    data = json.loads(path.read_text())
    data["mode"] = mode
    next_path = path.with_suffix(".next")
    next_path.write_text(json.dumps(data))
    next_path.replace(path)


def stop(process):
    if process is None or process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def run(args):
    matter_js = args.matter_js.resolve()
    actual = subprocess.check_output(["git", "-C", str(matter_js), "rev-parse", "HEAD"],
                                     text=True).strip()
    if actual != MATTER_JS_COMMIT:
        raise RuntimeError(f"Expected matter.js 0.18.0 commit {MATTER_JS_COMMIT}, got {actual}")
    nacho = matter_js / "node_modules/.bin/nacho-run"
    if not nacho.is_file():
        raise RuntimeError(f"matter.js dependencies missing: {nacho}")
    if not args.driver.is_file():
        raise RuntimeError(f"Crystal test driver missing: {args.driver}")

    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    device_store = logs / "matterjs-device"
    controller_state = logs / "controller.yml"
    trust_state = logs / "dcl-state.json"
    tls_key = logs / "tls.key"
    tls_cert = logs / "tls.crt"
    for path in (controller_state, trust_state, tls_key, tls_cert):
        path.unlink(missing_ok=True)

    device_log = logs / "matterjs-device.log"
    device_output = device_log.open("wb")
    device = None
    mirror = None
    mirror_output = None
    try:
        device = subprocess.Popen([str(nacho), "examples/device-onoff/src/DeviceNode.ts",
            f"--storage-path={device_store}", "--storage-clear",
            f"--port={args.device_port}", "--passcode=20202021", "--discriminator=3840"],
            cwd=matter_js, stdout=device_output, stderr=subprocess.STDOUT,
            start_new_session=True)
        code = await_pairing_code(device, device_log)
        run_command([str(args.driver), "provision", str(controller_state),
                     str(trust_state), code, str(args.device_port)],
                    logs / "provision.log", timeout=300)

        run_command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256",
                     "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
                     "-addext", "subjectAltName=IP:127.0.0.1",
                     "-addext", "basicConstraints=critical,CA:TRUE",
                     "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
                     "-keyout", str(tls_key), "-out", str(tls_cert)],
                    logs / "tls-cert.log")
        mirror_output = (logs / "dcl-mirror.log").open("wb")
        mirror = subprocess.Popen([sys.executable,
            str(Path(__file__).with_name("matterjs_vvs_dcl_mirror.py")),
            "--state", str(trust_state), "--cert", str(tls_cert),
            "--key", str(tls_key), "--port", str(args.dcl_port)],
            stdout=mirror_output, stderr=subprocess.STDOUT, start_new_session=True)
        await_gateway(mirror, tls_cert, args.dcl_port)
        verify_env = os.environ.copy()
        verify_env["SSL_CERT_FILE"] = str(tls_cert)
        if args.dcl_port != 443:
            verify_env["MATTER_VVS_TEST_DCL_PORT"] = str(args.dcl_port)
        for mode, expected in (("wrong-vid", "deny"), ("wrong-root", "deny"),
                               ("removed", "deny"), ("active", "accept")):
            set_mode(trust_state, mode)
            run_command([str(args.driver), "verify", str(controller_state),
                         str(trust_state), GATEWAY, str(args.device_port), expected],
                        logs / f"verify-{mode}.log", env=verify_env, timeout=180)
        print("PASS: independent matter.js 0.18.0 device VVS-bearing fabric, fresh CASE/VID challenge, "
              "HTTPS fixture trust-chain denials and acceptance", flush=True)
    finally:
        stop(mirror)
        stop(device)
        if mirror_output is not None:
            mirror_output.close()
        device_output.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matter-js", type=Path, required=True)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--device-port", type=int, default=5559)
    parser.add_argument("--dcl-port", type=int, default=8443)
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
