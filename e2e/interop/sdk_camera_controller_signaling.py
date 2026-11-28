#!/usr/bin/env python3
"""Verify pinned SDK Camera Controller signaling with a Crystal Camera over CASE.

This checks VideoStreamAllocate, legacy VideoStreamID ProvideOffer, and the
Provider's CurrentSessions response. It does not establish a media connection.
"""

import argparse
import os
from pathlib import Path
import subprocess
import sys

from sdk_jfc_switch_smoke import ManagedProcess, SETUP_PIN_PATTERN

SDK_TAG = "v1.6.0.0"
NODE_ID = 1
CAMERA_ENDPOINT = 1


def run(args):
    sdk = args.sdk.resolve()
    camera_binary = args.camera.resolve()
    controller_binary = sdk / "out/linux-x64-camera-controller-debug/chip-camera-controller"
    if not camera_binary.is_file() or not os.access(camera_binary, os.X_OK):
        raise RuntimeError(f"missing Crystal Camera executable: {camera_binary}")
    if not controller_binary.is_file() or not os.access(controller_binary, os.X_OK):
        raise RuntimeError(f"missing SDK Camera Controller executable: {controller_binary}")
    actual_tag = subprocess.check_output(
        ["git", "-C", str(sdk), "describe", "--tags", "--exact-match", "HEAD"],
        text=True,
    ).strip()
    if actual_tag != SDK_TAG:
        raise RuntimeError(f"expected official SDK {SDK_TAG}, got {actual_tag}")

    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    camera_state = logs / "camera-state"
    controller_state = logs / "controller-state"
    camera_state.mkdir(exist_ok=True)
    controller_state.mkdir(exist_ok=True)
    processes = []
    try:
        camera = ManagedProcess("camera", [str(camera_binary), "--no-interactive"],
                                camera_state, logs)
        processes.append(camera)
        pin = camera.expect(SETUP_PIN_PATTERN, 60).group(1)
        camera.expect(r"Starting in Commissioning Mode", 60)
        camera.start_background_drain()

        controller = ManagedProcess(
            "sdk-camera-controller",
            [str(controller_binary), "--storage-directory", str(controller_state),
             "--commissioner-vendor-id", "0xFFF1"],
            controller_state, logs,
        )
        processes.append(controller)
        controller.expect(r">[ \t]*(?:\r|$)", 90)

        paired = controller.command(f"pairing onnetwork {NODE_ID} {pin}")
        controller.expect(r"Commissioning complete.*success", 180, paired)
        controller.expect(r">[ \t]*(?:\r|$)", 30, paired)

        liveview = controller.command(
            f"liveview start {NODE_ID} --min-res-width 640 --min-res-height 480 "
            "--min-framerate 30"
        )
        controller.expect(r"Handle VideoStreamAllocateResponse command", 90, liveview)
        controller.expect(r"WebRTCProviderClient::HandleProvideOfferResponse", 90, liveview)

        sessions = controller.command(
            f"any read-by-id 0x553 0x0 {NODE_ID} {CAMERA_ENDPOINT}"
        )
        controller.expect(r"CurrentSessions:\s*1 entries", 60, sessions)
        print("PASS: pinned SDK Camera Controller allocated a Crystal video stream, "
              "completed ProvideOffer, and read one Provider session", flush=True)
    finally:
        for process in reversed(processes):
            process.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--camera", type=Path, required=True)
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
