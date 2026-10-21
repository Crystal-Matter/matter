Matter 1.6 SDK test credentials, sourced from
`project-chip/connectedhomeip` tag `v1.6.0.0`, paths
`credentials/test/revoked-attestation-certificates/indirect/` and
`credentials/test/attestation/Chip-Test-PAA-FFF1-Cert.der`.
The SDK is licensed under Apache-2.0. These test credentials are not
production trust anchors.

`Chip-Test-PAI-FFF1-03-Direct-CRL.der` was generated from the SDK's PAI 03
certificate and test key with `openssl ca -gencrl` (SHA-256, CRL number 1,
authority key identifier, and a 100-year test update interval). The private
key is not included here.
