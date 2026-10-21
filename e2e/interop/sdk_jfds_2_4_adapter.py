#!/usr/bin/env python3
"""Adapt the SDK's DER ICAC fixture to the Matter 1.6 Datastore wire type.

TC_JFDS_2_4 reads an X.509 DER certificate from JFC's INI store, then sends
it as AddAdmin/UpdateAdmin.ICAC. Those fields have a 400-byte Matter
certificate limit. This subclass changes only that input representation; all
official test steps and assertions are inherited unchanged.
"""

import logging
import os
import sys

from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

sys.path.insert(0, os.environ["MATTER_SDK_PYTHON_TESTING"])

from TC_JFDS_2_4 import TC_JFDS_2_4 as OfficialTC_JFDS_2_4  # noqa: E402
from matter.credentials.cert import (  # noqa: E402
    convert_chip_cert_to_x509_cert,
    convert_x509_cert_to_chip_cert,
)
from matter.testing.runner import default_matter_test_main  # noqa: E402


class TC_JFDS_2_4_Adapted(OfficialTC_JFDS_2_4):
    @staticmethod
    def _decode_cert_bytes(cert_str: str) -> bytes:
        der = OfficialTC_JFDS_2_4._decode_cert_bytes(cert_str)
        chip = convert_x509_cert_to_chip_cert(der)
        if len(chip) > 400:
            raise ValueError(f"SDK certificate remains above JFDS ICAC limit: {len(chip)} bytes")

        original = x509.load_der_x509_certificate(der)
        round_trip = x509.load_der_x509_certificate(convert_chip_cert_to_x509_cert(chip))
        original_key = original.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        round_trip_key = round_trip.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        if original.subject != round_trip.subject or original_key != round_trip_key:
            raise ValueError("Matter certificate changed SDK issuer subject or public key")
        logging.info("Adapted JFDS ICAC DER %d bytes to CHIP TLV %d bytes", len(der), len(chip))
        return chip


if __name__ == "__main__":
    default_matter_test_main()
