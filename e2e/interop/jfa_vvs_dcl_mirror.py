#!/usr/bin/env python3
"""Test-only HTTPS DCL VID signer records for the three-JFA Compose scenario."""

import argparse
import base64
import json
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


VENDOR_ID = 0xFFF1
ROOT_PATH = f"/dcl/pki/noc-vid-root-certificates/{VENDOR_ID}"
ICA_PATH = f"/dcl/pki/noc-vid-ica-certificates/{VENDOR_ID}"
SIGNER_PATH = f"/dcl/pki/noc-vid-certificates/{VENDOR_ID}/"


def record(state, key, certificate_type, is_root, vendor_id=VENDOR_ID):
    der = base64.b64decode(state[key])
    pem = "-----BEGIN CERTIFICATE-----\n" + base64.encodebytes(der).decode() + "-----END CERTIFICATE-----\n"
    return {"vid": vendor_id, "certificateType": certificate_type,
            "isRoot": is_root, "pemCert": pem}


def response(state, path):
    mode = state["mode"]
    if path == ROOT_PATH:
        records = [] if mode == "removed" else [record(
            state, "wrong_root_der" if mode == "wrong-root" else "root_der",
            "OperationalPKI", True,
            VENDOR_ID + 1 if mode == "wrong-vid" else VENDOR_ID)]
        return {"nocRootCertificates": {"certs": records}}
    if path == ICA_PATH:
        records = [] if mode == "removed" else [record(state, "ica_der", "OperationalPKI", False)]
        return {"nocIcaCertificates": {"certs": records}}
    if path == SIGNER_PATH + state["signer_skid"]:
        records = [] if mode == "removed" else [record(
            state, "wrong_signer_der" if mode == "wrong-signer" else "signer_der",
            "VIDSignerPKI", False)]
        return {"nocCertificatesByVidAndSkid": {"certs": records}}
    return None


def handler_for(state_path):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            try:
                payload = response(json.loads(state_path.read_text()), self.path)
            except (KeyError, ValueError) as error:
                self.send_error(500, str(error))
                return
            if payload is None:
                self.send_error(404)
                return
            body = json.dumps(payload).encode()
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
    server = ThreadingHTTPServer(("0.0.0.0", 443), handler_for(args.state))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("JFA test DCL mirror listening", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
