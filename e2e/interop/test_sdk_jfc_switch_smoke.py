import sys
import re
import tempfile
import time
import unittest
from pathlib import Path

from sdk_jfc_switch_smoke import ManagedProcess, SETUP_PIN_PATTERN, JFC_PROMPT_PATTERN


class ManagedProcessTest(unittest.TestCase):
    def test_setup_pin_can_have_fewer_than_eight_decimal_digits(self):
        match = re.search(SETUP_PIN_PATTERN, "  Setup PIN: 2204847\n")
        self.assertEqual(match.group(1), "2204847")

    def test_background_drain_keeps_noninteractive_device_running(self):
        with tempfile.TemporaryDirectory() as directory:
            script = (
                "import sys, time\n"
                "print('ready', flush=True)\n"
                "print('x' * 200000, flush=True)\n"
                "print('finished', flush=True)\n"
                "time.sleep(5)\n"
            )
            process = ManagedProcess(
                "fake-device", [sys.executable, "-u", "-c", script],
                Path(directory), Path(directory)
            )
            try:
                process.expect("ready", 2)
                process.start_background_drain()
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if "finished" in (Path(directory) / "fake-device.log").read_text():
                        break
                    time.sleep(0.05)
                else:
                    self.fail("background reader did not drain the device output")
            finally:
                process.close()

    def test_interactive_prompt_and_log_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            script = (
                "import sys\n"
                "print('>>> ', flush=True)\n"
                "for line in sys.stdin:\n"
                " print('Device (nodeId=2) commissioned with success', flush=True)\n"
                " print('>>> ', flush=True)\n"
            )
            process = ManagedProcess(
                "fake-jfc", [sys.executable, "-u", "-c", script],
                Path(directory), Path(directory)
            )
            try:
                process.expect(r">>>\s*$", 2)
                start = process.command("pairing onnetwork 2 20202021 --regular 1")
                process.expect(r"Device \(nodeId=2\) commissioned with success", 2, start)
            finally:
                process.close()
            log = (Path(directory) / "fake-jfc.log").read_text()
            self.assertIn("pairing onnetwork 2 20202021 --regular 1", log)
            self.assertIn("commissioned with success", log)

    def test_prompt_remains_detectable_when_async_log_follows(self):
        with tempfile.TemporaryDirectory() as directory:
            script = (
                "import sys, time\n"
                "sys.stdout.write('>>> \\r\\x1b[0Jasync log\\n')\n"
                "sys.stdout.flush()\n"
                "time.sleep(3)\n"
            )
            process = ManagedProcess(
                "fake-jfc", [sys.executable, "-u", "-c", script],
                Path(directory), Path(directory)
            )
            try:
                process.expect(JFC_PROMPT_PATTERN, 1)
            finally:
                process.close()


if __name__ == "__main__":
    unittest.main()
