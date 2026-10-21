import sys
import tempfile
import unittest
from pathlib import Path

from sdk_jfc_switch_smoke import ManagedProcess


class ManagedProcessTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
