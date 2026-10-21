#!/usr/bin/env python3
"""Verify that an SDK JFC issuer certificate retains identity after conversion."""

import sys
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


def identity(der):
    certificate = x509.load_der_x509_certificate(der)
    public_key = certificate.public_key().public_bytes(
        Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    return certificate.subject, public_key


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: sdk_cert_identity.py <original.der> <round-trip.der>")
    original = Path(sys.argv[1]).read_bytes()
    round_trip = Path(sys.argv[2]).read_bytes()
    if identity(original) != identity(round_trip):
        raise ValueError("SDK certificate subject or public key changed during conversion")


if __name__ == "__main__":
    main()
