"""Local headless protocol assertions used by the Linux SDK JCM runner."""

import tempfile
import threading
import time
import unittest
from pathlib import Path

import yaml

from sdk_jfc_jcm_live import inspect_identity


class LiveJcmHarnessTest(unittest.TestCase):
    def test_identity_probe_requires_nonce_and_public_chain(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "jfa-command.yml"

            def device():
                while not path.exists():
                    time.sleep(0.005)
                nonce = yaml.safe_load(path.read_text())["jfa_command"]["request"]["nonce"]
                path.write_text(yaml.safe_dump({"jfa_command": {"result": {
                    "status": "ok", "nonce": nonce, "fabric_present": True,
                    "inspected_fabric_id": 41216, "inspected_node_id": 11,
                    "inspected_root_public_key": b"\x04" + bytes(range(64)),
                    "inspected_root_certificate": b"root", "inspected_icac_certificate": b"icac",
                }}}))

            worker = threading.Thread(target=device)
            worker.start()
            result = inspect_identity(path, timeout=1)
            worker.join(timeout=1)
            self.assertEqual(result["inspected_node_id"], 11)
            self.assertEqual(result["inspected_icac_certificate"], b"icac")

    def test_identity_probe_rejects_missing_chain(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "jfa-command.yml"

            def device():
                while not path.exists():
                    time.sleep(0.005)
                nonce = yaml.safe_load(path.read_text())["jfa_command"]["request"]["nonce"]
                path.write_text(yaml.safe_dump({"jfa_command": {"result": {
                    "status": "ok", "nonce": nonce, "fabric_present": True,
                    "inspected_fabric_id": 41216, "inspected_node_id": 11,
                }}}))

            worker = threading.Thread(target=device)
            worker.start()
            with self.assertRaisesRegex(RuntimeError, "omitted"):
                inspect_identity(path, timeout=1)
            worker.join(timeout=1)


if __name__ == "__main__":
    unittest.main()
