#!/usr/bin/env python3
"""SDK 1.6 joining JFA with a DCL-backed VVS, driven into Crystal JCM."""

import base64
import json
import os
import random
import struct
import subprocess
from configparser import ConfigParser
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID, ObjectIdentifier

import matter.clusters as Clusters
from matter import CertificateAuthority
from matter.setup_payload import SetupPayload
from matter.storage import VolatileTemporaryPersistentStorage
from matter.testing.apps import JFAdministratorSubprocess, JFControllerSubprocess
from matter.testing.decorators import async_test_body
from matter.testing.matter_testing import MatterBaseTest
from matter.testing.runner import TestStep, default_matter_test_main

from sdk_jfc_jcm_live import inspect_identity


VENDOR_ID = 0xFFF1
ANCHOR_FABRIC_ID = 0xA100
SDK_FABRIC_ID = 2
SDK_JFA_NODE_ID = 11
SDK_CONTROLLER_NODE_ID = 201
SDK_JFA_PORT = 5541
SDK_JFA_ENDPOINT = 1
ROOT_ID_OID = ObjectIdentifier("1.3.6.1.4.1.37244.1.4")
ICA_ID_OID = ObjectIdentifier("1.3.6.1.4.1.37244.1.3")
SIGNER_ID_OID = ObjectIdentifier("1.3.6.1.4.1.37244.1.7")
STATEMENT_VERSION = 0x21
FABRIC_BINDING_VERSION = 1


def certificate(key, issuer_key, oid, number, label, parent=None, *, ca=False,
                path_length=None):
    now = datetime.now(timezone.utc)
    subject = x509.Name([
        x509.NameAttribute(oid, f"{number:016X}"),
        x509.NameAttribute(NameOID.COMMON_NAME, label),
    ])
    builder = (x509.CertificateBuilder()
               .subject_name(subject)
               .issuer_name(parent.subject if parent else subject)
               .public_key(key.public_key())
               .serial_number(number)
               .not_valid_before(now - timedelta(days=1))
               .not_valid_after(now + timedelta(days=1))
               .add_extension(x509.BasicConstraints(ca=ca, path_length=path_length), critical=True)
               .add_extension(x509.KeyUsage(digital_signature=not ca,
                                            content_commitment=False,
                                            key_encipherment=False,
                                            data_encipherment=False,
                                            key_agreement=False,
                                            key_cert_sign=ca,
                                            crl_sign=ca,
                                            encipher_only=False,
                                            decipher_only=False), critical=True)
               .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()),
                              critical=False)
               .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(
                   issuer_key.public_key()), critical=False))
    return builder.sign(issuer_key, hashes.SHA256())


def dcl_state(descriptor):
    root_key = ec.generate_private_key(ec.SECP256R1())
    ica_key = ec.generate_private_key(ec.SECP256R1())
    signer_key = ec.generate_private_key(ec.SECP256R1())
    wrong_root_key = ec.generate_private_key(ec.SECP256R1())
    wrong_signer_key = ec.generate_private_key(ec.SECP256R1())
    root = certificate(root_key, root_key, ROOT_ID_OID, 1, "DCL Root", ca=True,
                       path_length=1)
    ica = certificate(ica_key, root_key, ICA_ID_OID, 2, "DCL ICA", root,
                      ca=True, path_length=0)
    signer = certificate(signer_key, ica_key, SIGNER_ID_OID, 3, "VID signer", ica)
    wrong_root = certificate(wrong_root_key, wrong_root_key, ROOT_ID_OID, 4,
                             "Wrong Root", ca=True, path_length=1)
    wrong_signer = certificate(wrong_signer_key, ica_key, SIGNER_ID_OID, 5,
                               "Wrong signer", ica)
    skid = signer.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value.digest
    binding = (bytes([FABRIC_BINDING_VERSION]) + bytes(descriptor.rootPublicKey) +
               struct.pack(">QH", descriptor.fabricID, descriptor.vendorID))
    tbs = bytes([STATEMENT_VERSION]) + binding + skid
    der_signature = signer_key.sign(tbs, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der_signature)
    statement = bytes([STATEMENT_VERSION]) + skid + r.to_bytes(32, "big") + s.to_bytes(32, "big")
    if len(statement) != 85:
        raise RuntimeError("signed VVS has an unexpected size")

    from cryptography.hazmat.primitives.serialization import Encoding

    def encoded(cert):
        return base64.b64encode(cert.public_bytes(Encoding.DER)).decode()

    state = {
        "mode": "active",
        "root_der": encoded(root),
        "ica_der": encoded(ica),
        "signer_der": encoded(signer),
        "wrong_root_der": encoded(wrong_root),
        "wrong_signer_der": encoded(wrong_signer),
        "signer_skid": ":".join(f"{byte:02X}" for byte in skid),
    }
    return state, statement


def write_mode(path, state, mode):
    state["mode"] = mode
    temporary = path.with_suffix(".next")
    temporary.write_text(json.dumps(state))
    temporary.replace(path)


def run_driver(test, name, *args, env=None, timeout=360):
    logs = Path(test.user_params["vvs_logs"])
    command = [test.user_params["vvs_driver"], name, *map(str, args)]
    call_index = getattr(test, "vvs_driver_calls", 0) + 1
    test.vvs_driver_calls = call_index
    log = logs / f"crystal-{name}-{call_index:02d}.log"
    with log.open("wb") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                                timeout=timeout, env=env, check=False)
    if result.returncode:
        raise RuntimeError(f"Crystal {name} failed ({result.returncode}): " +
                           log.read_text(errors="replace")[-6000:])


async def read_identity(controller):
    result = await controller.ReadAttribute(
        nodeId=SDK_JFA_NODE_ID,
        attributes=[(0, Clusters.OperationalCredentials.Attributes.Fabrics),
                    (0, Clusters.OperationalCredentials.Attributes.NOCs)],
        returnClusterObject=True, fabricFiltered=False)
    creds = result[0][Clusters.OperationalCredentials]
    return creds.fabrics, creds.NOCs


def sdk_fabric(fabrics, nocs):
    matching = [fabric for fabric in fabrics if fabric.fabricID == SDK_FABRIC_ID and
                fabric.nodeID == SDK_JFA_NODE_ID]
    if len(matching) != 1:
        raise RuntimeError(f"SDK JFA original fabric absent or duplicated: {matching}")
    descriptor = matching[0]
    matching_nocs = [noc for noc in nocs if noc.fabricIndex == descriptor.fabricIndex]
    if len(matching_nocs) != 1:
        raise RuntimeError("SDK JFA original NOC absent or duplicated")
    return descriptor, matching_nocs[0]


class TC_SDK_JFA_VVS(MatterBaseTest):
    @async_test_body
    async def setup_class(self):
        super().setup_class()
        self.fabric_b_admin = None
        self.fabric_b_ctrl = None
        self.controller = None
        self.ca_manager = None
        self.ca_storage = None

    def teardown_class(self):
        if self.fabric_b_admin:
            self.fabric_b_admin.terminate()
        if self.fabric_b_ctrl:
            self.fabric_b_ctrl.terminate()
        if self.controller:
            self.controller.Shutdown()
        if self.ca_manager:
            self.ca_manager.Shutdown()
        if self.ca_storage:
            self.ca_storage.Shutdown()
        super().teardown_class()

    def steps_TC_SDK_JFA_VVS(self) -> list[TestStep]:
        return [
            TestStep("1", "SDK JFC provisions SDK JFA with an Anchor ICAC"),
            TestStep("2", "SDK controller installs a signed VVS without VVSC"),
            TestStep("3", "Crystal rejects stale or invalid DCL signer records"),
            TestStep("4", "Crystal denies JCM without consent and preserves fabrics"),
            TestStep("5", "Crystal joins SDK JFA using VVS and retains both ICACs"),
        ]

    @async_test_body
    async def test_TC_SDK_JFA_VVS(self):
        logs = Path(self.user_params["vvs_logs"])
        b_store = Path(self.user_params["vvs_sdk_store"])
        dcl_path = Path(self.user_params["vvs_dcl_state"])
        b_store.mkdir(parents=True, exist_ok=True)
        self.step("1")
        passcode = random.randint(110220011, 110220999)
        rpc_port = self.get_random_port()
        discriminator = random.randint(0, 4095)
        secured_commissioner_port = self.get_random_port()
        jfa_kwargs = dict(app=self.user_params["vvs_sdk_jfa"], prefix="JFA-B",
                          storage_dir=str(b_store), port=SDK_JFA_PORT,
                          discriminator=discriminator, passcode=passcode,
                          extra_args=["--capabilities", "0x04", "--rpc-server-port",
                                      str(rpc_port), "--secured-commissioner-port",
                                      str(secured_commissioner_port)])
        self.fabric_b_admin = JFAdministratorSubprocess(**jfa_kwargs)
        self.sdk_kvs_owner = self.fabric_b_admin
        self.fabric_b_admin.start(expected_output="Server initialization complete", timeout=30)
        self.fabric_b_ctrl = JFControllerSubprocess(
            self.user_params["vvs_sdk_jfc"], prefix="JFC-B", rpc_server_port=rpc_port,
            storage_dir=str(b_store), vendor_id=VENDOR_ID)
        self.fabric_b_ctrl.start(expected_output="CHIP task running", timeout=30)
        self.fabric_b_ctrl.send(
            message=f"pairing onnetwork {SDK_JFA_NODE_ID} {passcode} --anchor true --commissioner-name beta",
            expected_output=f"[JF] Anchor Administrator (nodeId={SDK_JFA_NODE_ID}) commissioned with success",
            timeout=90)
        Path(self.user_params["vvs_a_discovery_gate"]).touch()

        config = ConfigParser()
        if not config.read(b_store / "chip_tool_config.beta.ini"):
            raise RuntimeError("SDK JFC did not persist beta issuer")
        sdk_config = {
            "ExampleOpCredsCAKey2": config.get("Default", "ExampleOpCredsCAKey0"),
            "ExampleOpCredsICAKey2": config.get("Default", "ExampleOpCredsICAKey0"),
            "ExampleCARootCert2": config.get("Default", "ExampleCARootCert0"),
            "ExampleCAIntermediateCert2": config.get("Default", "ExampleCAIntermediateCert0"),
        }
        cats = base64.b64decode(config.get("Default", "CommissionerCATs"))[::-1].hex().strip("0")
        if not cats:
            raise RuntimeError("SDK commissioner CATs are absent")
        self.ca_storage = VolatileTemporaryPersistentStorage(
            {"caList": {"2": [{"fabricId": SDK_FABRIC_ID, "vendorId": VENDOR_ID}]}},
            sdk_config)
        self.ca_manager = CertificateAuthority.CertificateAuthorityManager(
            chipStack=self.matter_stack._chip_stack, persistentStorage=self.ca_storage)
        self.ca_manager.LoadAuthoritiesFromStorage()
        self.controller = self.ca_manager.activeCaList[0].adminList[0].NewController(
            nodeId=SDK_CONTROLLER_NODE_ID,
            paaTrustStorePath=str(self.matter_test_config.paa_trust_store_path),
            catTags=[int(cats, 16)])
        fabrics, nocs = await read_identity(self.controller)
        descriptor, noc = sdk_fabric(fabrics, nocs)
        original_icac = bytes(noc.icac or b"")
        if len(fabrics) != 1 or not original_icac or noc.vvsc not in (None, b""):
            raise RuntimeError("SDK JFA did not start with exactly one ICAC-backed fabric")
        if descriptor.vendorID != VENDOR_ID:
            raise RuntimeError("SDK JFA original fabric has an unexpected Vendor ID")

        self.step("2")
        state, statement = dcl_state(descriptor)
        await self.controller.SendCommand(
            SDK_JFA_NODE_ID, 0,
            Clusters.OperationalCredentials.Commands.SetVIDVerificationStatement(
                vendorID=VENDOR_ID, VIDVerificationStatement=statement))
        fabrics, nocs = await read_identity(self.controller)
        installed, installed_noc = sdk_fabric(fabrics, nocs)
        if (bytes(installed.VIDVerificationStatement or b"") != statement or
                bytes(installed_noc.icac or b"") != original_icac or
                installed_noc.vvsc not in (None, b"")):
            raise RuntimeError("SDK JFA changed its ICAC/VVSC or failed VVS readback")
        write_mode(dcl_path, state, "active")
        print("PASS: independent SDK JFA carries signed VVS and original ICAC without VVSC", flush=True)

        # The read-only PASE probe leaves the SDK commissioning window active.
        # Restore the post-VVS KVS after checking each attempted handoff, so
        # the next case starts from the same commissioned device state.
        kvs_path = Path(self.sdk_kvs_owner.kvs_tmp_file.name)
        kvs_snapshot = kvs_path.read_bytes()

        def restart_from_snapshot():
            self.fabric_b_admin.terminate()
            kvs_path.write_bytes(kvs_snapshot)
            self.fabric_b_admin = JFAdministratorSubprocess(
                **jfa_kwargs, kvs_path=str(kvs_path))
            self.fabric_b_admin.start(expected_output="Server initialization complete", timeout=30)
            self.controller.MarkSessionDefunct(SDK_JFA_NODE_ID)

        self.step("3")
        window = await self.controller.OpenJointCommissioningWindow(
            nodeId=SDK_JFA_NODE_ID, endpointId=SDK_JFA_ENDPOINT,
            timeout=900, iteration=1000, discriminator=1261)
        code = SetupPayload().GenerateManualPairingCode(
            passcode=window.setupPinCode, discriminator=1261)
        dcl_env = os.environ.copy()
        dcl_env.update(SSL_CERT_FILE=self.user_params["vvs_tls_cert"],
                       MATTER_JCM_TEST_DCL_GATEWAY_URL="https://127.0.0.1",
                       MATTER_JCM_TEST_B_HOST=self.user_params["vvs_sdk_ipv6_host"])
        run_driver(self, "probe-dcl", code, SDK_JFA_PORT, "https://127.0.0.1",
                   dcl_path, env=dcl_env, timeout=90)
        print("PASS: Crystal rejected invalid/removed/stale DCL records and accepted the SDK VVS", flush=True)

        self.step("4")
        await self.controller.SendCommand(
            SDK_JFA_NODE_ID, 0,
            Clusters.AdministratorCommissioning.Commands.RevokeCommissioning(),
            timedRequestTimeoutMs=6000)
        restart_from_snapshot()
        window = await self.controller.OpenJointCommissioningWindow(
            nodeId=SDK_JFA_NODE_ID, endpointId=SDK_JFA_ENDPOINT,
            timeout=900, iteration=1000, discriminator=1261)
        code = SetupPayload().GenerateManualPairingCode(
            passcode=window.setupPinCode, discriminator=1261)
        denied_env = dcl_env.copy()
        denied_env["MATTER_JCM_TEST_CONSENT"] = "deny"
        driver_args = (self.user_params["vvs_bootstrap"],
                       self.user_params["vvs_a_code"], code,
                       self.user_params["vvs_b_root"],
                       self.user_params["vvs_a_exchange"],
                       self.user_params["vvs_a_command"],
                       self.user_params["vvs_cross_icac"],
                       5540, SDK_JFA_PORT)
        run_driver(self, "commission", *driver_args, env=denied_env)
        fabrics, nocs = await read_identity(self.controller)
        denied_descriptor, denied_noc = sdk_fabric(fabrics, nocs)
        if (len(fabrics) != 1 or bytes(denied_descriptor.VIDVerificationStatement or b"") != statement or
                bytes(denied_noc.icac or b"") != original_icac):
            raise RuntimeError("Consent denial changed SDK JFA fabric state")
        a_identity = inspect_identity(Path(self.user_params["vvs_a_command"]))
        if len(a_identity.get("inspected_datastore_admin_entries", [])) != 1:
            raise RuntimeError("Consent denial registered SDK JFA in Crystal A Datastore")
        print("PASS: consent denial preserved SDK JFA original fabric", flush=True)

        # Restore only after verifying that consent denial changed neither
        # fabric; revoke the remaining PASE commissioning window first.
        await self.controller.SendCommand(
            SDK_JFA_NODE_ID, 0,
            Clusters.AdministratorCommissioning.Commands.RevokeCommissioning(),
            timedRequestTimeoutMs=6000)
        restart_from_snapshot()
        restarted_fabrics, restarted_nocs = await read_identity(self.controller)
        restarted_descriptor, restarted_noc = sdk_fabric(restarted_fabrics, restarted_nocs)
        if (len(restarted_fabrics) != 1 or
                bytes(restarted_descriptor.VIDVerificationStatement or b"") != statement or
                bytes(restarted_noc.icac or b"") != original_icac):
            raise RuntimeError("SDK JFA did not recover its VVS and original ICAC after restart")
        self.step("5")
        window = await self.controller.OpenJointCommissioningWindow(
            nodeId=SDK_JFA_NODE_ID, endpointId=SDK_JFA_ENDPOINT,
            timeout=900, iteration=1000, discriminator=1261)
        code = SetupPayload().GenerateManualPairingCode(
            passcode=window.setupPinCode, discriminator=1261)
        allowed_env = dcl_env.copy()
        allowed_env["MATTER_JCM_TEST_SKIP_ANCHOR_COMMISSION"] = "1"
        successful_args = list(driver_args)
        successful_args[2] = code
        run_driver(self, "commission", *successful_args, env=allowed_env)
        cross_icac = Path(self.user_params["vvs_cross_icac"]).read_bytes()
        fabrics, nocs = await read_identity(self.controller)
        sdk_descriptor, sdk_noc = sdk_fabric(fabrics, nocs)
        joining = [fabric for fabric in fabrics if fabric.fabricID == ANCHOR_FABRIC_ID]
        if len(fabrics) != 2 or len(joining) != 1 or len(nocs) != 2:
            raise RuntimeError("SDK JFA did not retain both fabrics after Crystal JCM")
        joined_nocs = [noc for noc in nocs if noc.fabricIndex == joining[0].fabricIndex]
        if (len(joined_nocs) != 1 or bytes(joined_nocs[0].icac or b"") != cross_icac or
                joined_nocs[0].vvsc not in (None, b"") or
                bytes(sdk_noc.icac or b"") != original_icac or
                sdk_noc.vvsc not in (None, b"") or
                bytes(sdk_descriptor.VIDVerificationStatement or b"") != statement):
            raise RuntimeError("SDK JFA did not preserve original VVS/ICAC and joined cross-ICAC")
        index = await self.controller.ReadAttribute(
            SDK_JFA_NODE_ID, [(SDK_JFA_ENDPOINT,
                               Clusters.JointFabricAdministrator.Attributes.AdministratorFabricIndex)],
            returnClusterObject=True)
        admin_index = index[SDK_JFA_ENDPOINT][
            Clusters.JointFabricAdministrator].administratorFabricIndex
        if admin_index != joining[0].fabricIndex:
            raise RuntimeError("SDK JFA AdministratorFabricIndex did not select Crystal fabric")
        print("PASS: Crystal Anchor JCM joined independent SDK JFA with signed VVS", flush=True)


if __name__ == "__main__":
    default_matter_test_main()
