#!/usr/bin/env python3
"""Commission Crystal Camera fixture from pinned matter.js and verify Requestor wire signaling."""
import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

MATTER_JS_COMMIT = "7e1f5d7892dcea4330828b6a82d31ffe2a04cc0b"
PASSCODE = re.compile(r"Setup PIN:\s*(\d+)")
DISCRIMINATOR = re.compile(r"Discriminator:\s*(\d+)")


def stop(process):
    if process is None or process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matter-js", type=Path, required=True)
    parser.add_argument("--camera", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    args = parser.parse_args()
    matter_js = args.matter_js.resolve()
    actual = subprocess.check_output(["git", "-C", str(matter_js), "rev-parse", "HEAD"], text=True).strip()
    if actual != MATTER_JS_COMMIT:
        raise RuntimeError(f"Expected pinned matter.js {MATTER_JS_COMMIT}, got {actual}")
    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    control = logs / "control"
    control.mkdir(exist_ok=True)
    for path in control.glob("end-*"):
        path.unlink()
    target = matter_js / "examples/control-onoff/src/CameraMediaInterop.ts"
    shutil.copyfile(Path(__file__).with_name("matterjs_camera_media.ts"), target)
    camera_log = logs / "camera.log"
    requestor_log = logs / "requestor.log"
    camera_output = camera_log.open("wb")
    camera = None
    try:
        env = os.environ.copy()
        env["MATTER_CAMERA_SIGNALING_CONTROL_DIR"] = str(control)
        camera = subprocess.Popen([str(args.camera.resolve()), "--no-interactive"],
                                  cwd=logs, env=env, stdout=camera_output,
                                  stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 90
        passcode = None
        discriminator = None
        while time.monotonic() < deadline:
            if camera.poll() is not None:
                raise RuntimeError(f"Camera exited {camera.returncode}:\n" + camera_log.read_text(errors="replace")[-6000:])
            output = camera_log.read_text(errors="replace")
            passcode_match = PASSCODE.search(output)
            discriminator_match = DISCRIMINATOR.search(output)
            if passcode_match and discriminator_match:
                passcode = passcode_match.group(1)
                discriminator = discriminator_match.group(1)
                break
            time.sleep(0.2)
        if passcode is None or discriminator is None:
            raise RuntimeError("Camera setup credentials did not appear:\n" + camera_log.read_text(errors="replace")[-6000:])
        nacho = matter_js / "node_modules/.bin/nacho-run"
        with requestor_log.open("wb") as output:
            result = subprocess.run([str(nacho), str(target.relative_to(matter_js)),
                                     passcode, discriminator, str(control)],
                                    cwd=matter_js, stdout=output, stderr=subprocess.STDOUT,
                                    timeout=240, check=False)
        if result.returncode:
            raise RuntimeError(f"matter.js Requestor exited {result.returncode}:\n" + requestor_log.read_text(errors="replace")[-8000:] +
                               "\nCamera:\n" + camera_log.read_text(errors="replace")[-8000:])
        print(requestor_log.read_text(errors="replace")[-3000:], flush=True)
    finally:
        stop(camera)
        camera_output.close()
        target.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
