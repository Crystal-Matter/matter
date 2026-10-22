#!/usr/bin/env python3
"""Ephemeral HTTPS DCL response fixture for SDK-backed Joint Commissioning.

The file contains only an SDK issuer's public DER certificate. It is not a DCL
ledger, and its local TLS certificate is trusted only by the test processes.
"""

import argparse
import base64
from configparser import ConfigParser
import json
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


VENDOR_ID = 0xFFF1
ROOT_PATH = f"/dcl/pki/noc-vid-root-certificates/{VENDOR_ID}"


def sdk_public_root_der(storage_dir):
    for path in storage_dir.glob("chip_tool_config*.ini"):
        config = ConfigParser()
        if config.read(path) and config.has_option("Default", "ExampleCARootCert0"):
            encoded = "".join(config.get("Default", "ExampleCARootCert0").split())
            if encoded.startswith("0x"):
                encoded = encoded[2:]
            try:
                return bytes.fromhex(encoded)
            except ValueError:
                return base64.b64decode(encoded, validate=True)
    raise RuntimeError("SDK JFC did not persist its public operational root certificate")


def root_response(mode, certificate):
    if mode == "removed":
        certificates = []
    else:
        if mode not in ("active", "wrong-vid"):
            raise ValueError(f"unknown test DCL mode: {mode}")
        pem = ("-----BEGIN CERTIFICATE-----\n"
               + base64.encodebytes(certificate).decode("ascii")
               + "-----END CERTIFICATE-----\n")
        certificates = [{"vid": VENDOR_ID if mode == "active" else 0xFFF2,
                         "certificateType": "OperationalPKI", "isRoot": True,
                         "pemCert": pem}]
    return {"nocRootCertificates": {"certs": certificates}}


def handler_for(state_path):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != ROOT_PATH:
                self.send_error(404)
                return
            state = json.loads(state_path.read_text())
            body = json.dumps(root_response(state["mode"],
                                            base64.b64decode(state["root_der"]))).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format_string, *args):
            print(format_string % args, flush=True)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--cert", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 443), handler_for(args.state))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("test DCL mirror listening on https://127.0.0.1", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
