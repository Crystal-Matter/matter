#!/usr/bin/env python3
"""Decode synthetic Crystal Camera video through the pinned SDK Controller.

The SDK Controller handles Matter CASE signaling and forwards WebRTC H.264 RTP
to localhost UDP port 5000. GStreamer decodes those packets to raw frames.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.request import urlopen

from sdk_jfc_switch_smoke import ManagedProcess, SETUP_PIN_PATTERN

SDK_TAG = "v1.6.0.0"
NODE_ID = 1
MEDIA_STATE = "http://127.0.0.1:18753/state"
FRAME_SIZE = 640 * 480 * 3 // 2


def wait_for_host(host, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if host.process.poll() is not None:
            raise RuntimeError(f"media host exited {host.process.returncode}")
        try:
            with urlopen(MEDIA_STATE, timeout=1):
                return
        except OSError:
            time.sleep(0.2)
    raise RuntimeError("media host did not start")


def wait_for_frames(host, decoder, frames, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if host.process.poll() is not None:
            raise RuntimeError("media host exited before sending frames")
        if decoder.poll() is not None:
            raise RuntimeError(f"GStreamer decoder exited {decoder.returncode}")
        decoded = sorted(frames.glob("frame-*.i420"))
        decoded = [path for path in decoded if path.stat().st_size == FRAME_SIZE]
        with urlopen(MEDIA_STATE, timeout=3) as response:
            sessions = json.load(response)
        if (len(decoded) >= 3 and len(sessions) == 1 and
                next(iter(sessions.values()))["connection"] == "connected"):
            # Every second synthetic frame changes luma; prove decoded pixels
            # were delivered through SDK WebRTC, RTP forwarding and H.264.
            luminance = {path.read_bytes()[0] for path in decoded[:10]}
            if len(luminance) >= 2:
                return len(decoded), luminance
        time.sleep(0.5)
    raise RuntimeError("SDK Controller did not deliver changing decoded H.264 frames")


def run(args):
    sdk = args.sdk.resolve()
    camera_binary = args.camera.resolve()
    controller_binary = sdk / "out/linux-x64-camera-controller-debug/chip-camera-controller"
    for binary in (camera_binary, controller_binary):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError(f"missing executable: {binary}")
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
    frames = logs / "frames"
    for directory in (camera_state, controller_state, frames):
        directory.mkdir(exist_ok=True)

    processes = []
    decoder = None
    decoder_log = (logs / "decoder.log").open("wb")
    try:
        host = ManagedProcess("media-host", [str(args.media_python.resolve()),
                              str(Path(__file__).with_name("camera_media_host.py"))], logs, logs)
        processes.append(host)
        host.start_background_drain()
        wait_for_host(host)

        decoder = subprocess.Popen([
            "gst-launch-1.0", "-q", "udpsrc", "port=5000",
            "caps=application/x-rtp,media=video,encoding-name=H264,payload=96,clock-rate=90000",
            "!", "rtph264depay", "!", "h264parse", "!", "avdec_h264", "!",
            "videoconvert", "!", "video/x-raw,format=I420,width=640,height=480", "!",
            "multifilesink", f"location={frames}/frame-%05d.i420",
        ], stdout=decoder_log, stderr=subprocess.STDOUT, start_new_session=True)

        camera = ManagedProcess("camera", [str(camera_binary), "--no-interactive"],
                                camera_state, logs)
        processes.append(camera)
        pin = camera.expect(SETUP_PIN_PATTERN, 60).group(1)
        camera.expect(r"Starting in Commissioning Mode", 60)
        camera.start_background_drain()

        controller = ManagedProcess("sdk-camera-controller",
                                    [str(controller_binary), "--storage-directory",
                                     str(controller_state), "--commissioner-vendor-id", "0xFFF1"],
                                    controller_state, logs)
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
        controller.expect(r"WebRTCManager::HandleAnswer", 90, liveview)
        count, luminance = wait_for_frames(host, decoder, frames)
        print(f"PASS: SDK Camera Controller decoded {count} H.264 frames at "
              f"640x480, changing luma {sorted(luminance)}", flush=True)
    finally:
        for process in reversed(processes):
            process.close()
        if decoder is not None:
            decoder.terminate()
            try:
                decoder.wait(timeout=5)
            except subprocess.TimeoutExpired:
                decoder.kill()
                decoder.wait(timeout=5)
        decoder_log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--camera", type=Path, required=True)
    parser.add_argument("--media-python", type=Path, required=True)
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
