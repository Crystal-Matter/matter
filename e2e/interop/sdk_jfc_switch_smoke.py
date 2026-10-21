#!/usr/bin/env python3
"""Commission a Crystal switch using the official Matter 1.6 JFC and JFA.

All three processes run in one Linux network namespace for operational mDNS.
The caller builds them first. This harness has no third-party dependencies.
"""

import argparse
import os
import pty
import re
import select
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

SETUP_PIN_PATTERN = r"Setup PIN:\s*(\d{1,8})(?!\d)"


class ManagedProcess:
    def __init__(self, name, argv, cwd, log_dir, env=None):
        self.name = name
        self.master, slave = pty.openpty()
        self.log = (log_dir / f"{name}.log").open("wb")
        self.process = subprocess.Popen(
            argv,
            cwd=cwd,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            start_new_session=True,
            close_fds=True,
        )
        os.close(slave)
        self.output = ""
        self.reader = None
        self.reader_stop = threading.Event()

    def drain(self, seconds=0.2):
        readable, _, _ = select.select([self.master], [], [], seconds)
        if readable:
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                chunk = b""
            if chunk:
                self.log.write(chunk)
                self.log.flush()
                self.output += chunk.decode("utf-8", "replace")

    def expect(self, pattern, timeout, since=0):
        deadline = time.monotonic() + timeout
        expression = re.compile(pattern, re.IGNORECASE | re.MULTILINE)
        while time.monotonic() < deadline:
            self.drain(min(0.2, deadline - time.monotonic()))
            match = expression.search(self.output, since)
            if match:
                return match
            if self.process.poll() is not None:
                break
        tail = self.output[-5000:]
        raise RuntimeError(
            f"{self.name}: timed out or exited ({self.process.poll()}) "
            f"waiting for {pattern!r}; log tail:\n{tail}"
        )

    def command(self, value):
        start = len(self.output)
        os.write(self.master, (value + "\n").encode())
        return start

    def start_background_drain(self):
        """Keep a chatty device from blocking when another process is awaited."""
        if self.reader is not None:
            return

        def read_until_stopped():
            while not self.reader_stop.is_set():
                self.drain(0.2)

        self.reader = threading.Thread(target=read_until_stopped, daemon=True)
        self.reader.start()

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        self.reader_stop.set()
        if self.reader is not None:
            self.reader.join(timeout=2)
        self.drain(0)
        os.close(self.master)
        self.log.close()


def run(args):
    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    root = args.sdk.resolve()
    jfa_bin = root / "objdir-jf/linux-x64-jf-admin-app-ipv6only-no-ble-no-wifi-clang/jfa-app"
    jfc_bin = root / "objdir-jf/linux-x64-jf-control-app-ipv6only-no-ble-no-wifi-clang/jfc-app"
    switch_bin = args.switch.resolve()
    for binary in (jfa_bin, jfc_bin, switch_bin):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError(f"missing executable: {binary}")

    processes = []
    try:
        jfa_state = logs / "jfa-state"
        switch_state = logs / "switch-state"
        jfa_state.mkdir(exist_ok=True)
        switch_state.mkdir(exist_ok=True)
        # The SDK JF guide requires an existing KVS file.
        kvs = jfa_state / "kvs"
        kvs.touch(exist_ok=True)
        jfa = ManagedProcess(
            "jfa",
            [str(jfa_bin), "--capabilities", "0x4", "--passcode", "11022033",
             "--discriminator", "3840", "--secured-device-port", "5533",
             "--rpc-server-port", "33033", "--KVS", str(kvs)],
            jfa_state, logs,
        )
        processes.append(jfa)
        jfa.start_background_drain()
        # The SDK JFA starts its Pigweed server before the JFC connects.
        time.sleep(3)
        if jfa.process.poll() is not None:
            raise RuntimeError("official JFA exited during startup")

        switch_env = os.environ.copy()
        switch_env["MATTER_SWITCH_IP_ADDRESS"] = "fd42:4d41:5454::2"
        switch = ManagedProcess("switch", [str(switch_bin), "--no-interactive"],
                                switch_state, logs, switch_env)
        processes.append(switch)
        pin = switch.expect(SETUP_PIN_PATTERN, 60).group(1)
        switch.expect(r"Starting in Commissioning Mode", 60)
        switch.start_background_drain()

        jfc_state = logs / "jfc-state"
        jfc_state.mkdir(exist_ok=True)
        jfc = ManagedProcess(
            "jfc",
            [str(jfc_bin), "--rpc-server-port", "33033", "--storage-directory",
             str(jfc_state), "--commissioner-vendor-id", "0xFFF1"],
            jfc_state, logs,
        )
        processes.append(jfc)
        jfc.expect(r">>>\s*$", 90)

        anchor_start = jfc.command("pairing onnetwork-long 1 11022033 3840 --anchor true")
        jfc.expect(r"Anchor Administrator \(nodeId=1\) commissioned with success", 180, anchor_start)
        jfc.expect(r">>>\s*$", 30, anchor_start)

        device_start = jfc.command(f"pairing onnetwork 2 {pin} --regular 1")
        jfc.expect(r"Device \(nodeId=2\) commissioned with success", 180, device_start)
        jfc.expect(r">>>\s*$", 30, device_start)

        fabric_start = jfc.command("operationalcredentials read fabrics 2 0")
        jfc.expect(r"Fabrics:\s*[1-9]\d*\s+entries", 90, fabric_start)
        jfc.expect(r">>>\s*$", 30, fabric_start)

        acl_start = jfc.command("accesscontrol read acl 2 0")
        jfc.expect(r"ACL:\s*[1-9]\d*\s+entries", 90, acl_start)
        print(f"PASS: official JFC/JFA commissioned Crystal switch; logs: {logs}")
    finally:
        for process in reversed(processes):
            process.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--switch", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args)
    except (OSError, RuntimeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
