#!/usr/bin/env python3
"""Convert an SDK JFC issuer certificate to Matter TLV without changing identity."""

import sys
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from matter import native
from matter.credentials.cert import (
    convert_chip_cert_to_x509_cert,
    convert_x509_cert_to_chip_cert,
)


def identity(der):
    certificate = x509.load_der_x509_certificate(der)
    public_key = certificate.public_key().public_bytes(
        Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    return certificate.subject, public_key


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: sdk_cert_to_chip.py <sdk-cert.der> <matter-cert.tlv>")
    original = Path(sys.argv[1]).read_bytes()
    native.Init()
    converted = convert_x509_cert_to_chip_cert(original)
    round_trip = convert_chip_cert_to_x509_cert(converted)
    if identity(original) != identity(round_trip):
        raise ValueError("SDK certificate subject or public key changed during conversion")
    Path(sys.argv[2]).write_bytes(converted)


if __name__ == "__main__":
    main()
