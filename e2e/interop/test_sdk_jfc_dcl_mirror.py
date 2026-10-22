import base64
import json
import ssl
import subprocess
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

from sdk_jfc_dcl_mirror import ROOT_PATH, VENDOR_ID, handler_for, root_response, sdk_public_root_der
from http.server import ThreadingHTTPServer


class DclMirrorTest(unittest.TestCase):
    def test_sdk_public_root_accepts_hex_and_base64_storage(self):
        certificate = b"\x30\x03\x01\x02\x03"
        with tempfile.TemporaryDirectory() as directory:
            storage = Path(directory)
            config = storage / "chip_tool_config.alpha.ini"
            for encoded in (certificate.hex(), base64.b64encode(certificate).decode()):
                config.write_text(f"[Default]\nExampleCARootCert0={encoded}\n")
                self.assertEqual(sdk_public_root_der(storage), certificate)

    def test_active_wrong_vid_and_removed_are_distinct(self):
        certificate = b"public certificate"
        active = root_response("active", certificate)["nocRootCertificates"]["certs"]
        wrong = root_response("wrong-vid", certificate)["nocRootCertificates"]["certs"]
        removed = root_response("removed", certificate)["nocRootCertificates"]["certs"]
        self.assertEqual(active[0]["vid"], VENDOR_ID)
        self.assertEqual(wrong[0]["vid"], 0xFFF2)
        self.assertEqual(removed, [])
        self.assertEqual(active[0]["pemCert"], wrong[0]["pemCert"])

    def test_https_mirror_switches_active_vid_records(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cert = root / "server.pem"
            key = root / "server.key"
            state = root / "state.json"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                            "-sha256", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
                            "-addext", "subjectAltName=IP:127.0.0.1",
                            "-addext", "basicConstraints=critical,CA:TRUE",
                            "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
                            "-keyout", str(key), "-out", str(cert)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(state))
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                client_context = ssl.create_default_context(cafile=str(cert))
                for mode, expected_vids in (("wrong-vid", [0xFFF2]),
                                            ("removed", []), ("active", [VENDOR_ID])):
                    state.write_text(json.dumps({
                        "mode": mode,
                        "root_der": base64.b64encode(b"public certificate").decode(),
                    }))
                    with urllib.request.urlopen(
                            f"https://127.0.0.1:{server.server_port}{ROOT_PATH}",
                            context=client_context, timeout=2) as response:
                        records = json.load(response)["nocRootCertificates"]["certs"]
                    self.assertEqual([record["vid"] for record in records], expected_vids)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
