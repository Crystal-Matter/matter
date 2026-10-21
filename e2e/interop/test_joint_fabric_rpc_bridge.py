"""Dependency-free transport and service smoke tests for the SDK JFC bridge."""

import base64
import json
import os
import socket
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest import mock

from joint_fabric_rpc_bridge import (
    METHOD_IDS,
    FAILED_PRECONDITION,
    OUT_OF_RANGE,
    REQUEST,
    RESPONSE,
    RPC_CHANNEL,
    SERVER_ERROR,
    SERVICE_ID,
    SERVER_STREAM,
    UNIMPLEMENTED,
    FabricProbe,
    JointFabricService,
    RpcPacket,
    HandoffQueue,
    CsrMailbox,
    decode_frame,
    encode_frame,
    handle_connection,
    rpc_id,
)


class RpcBridgeTest(unittest.TestCase):
    def test_ids_match_matter_1_6_pigweed_hashes(self):
        self.assertEqual(rpc_id("JointFabric"), 0xD030235C)
        self.assertEqual(METHOD_IDS["GetStream"], 0x8CA3ACD3)
        self.assertEqual(METHOD_IDS["TransferOwnership"], 0x63003FED)
        self.assertEqual(METHOD_IDS["ResponseStream"], 0x49BDAE6F)

    def test_hdlc_matches_sdk_golden_frame(self):
        payload = bytes.fromhex("08001001")
        frame = encode_frame(payload)
        self.assertEqual(frame.hex(), "7ea503080010010651c2477e")
        self.assertEqual(decode_frame(frame[1:-1]), payload)
        with self.assertRaisesRegex(ValueError, "CRC"):
            decode_frame(frame[1:-2] + b"\x00")

    def test_packet_round_trip_preserves_pigweed_call_id(self):
        request = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["TransferOwnership"],
                            b"\x08\x2a", call_id=41)
        self.assertEqual(RpcPacket.decode(request.encode()), request)
        response = request.reply(SERVER_ERROR, UNIMPLEMENTED)
        self.assertEqual(RpcPacket.decode(response.encode()), response)

    def test_optional_crystal_fabric_probe_writes_headless_request(self):
        with tempfile.TemporaryDirectory() as directory:
            key = bytes(range(65))
            path = Path(directory) / "jfa-command.yml"

            def crystal_result(content):
                self.assertIn('operation: "inspect-fabric"', content)
                self.assertIn("fabric_id: 41216", content)
                self.assertIn("root_public_key: !!binary ", content)
                nonce = content.split('nonce: "', 1)[1].split('"', 1)[0]
                return {"jfa_command": {"result": {
                    "status": "ok", "fabric_present": True, "nonce": nonce,
                    "inspected_fabric_id": 41216, "inspected_root_public_key": key,
                }}}

            with mock.patch.dict("sys.modules", {"yaml": types.SimpleNamespace(safe_load=crystal_result)}):
                self.assertTrue(FabricProbe(path, 41216, key).verify())
            self.assertTrue(path.exists())

    def test_get_stream_stays_open_and_handoff_fails_explicitly_over_tcp(self):
        client, server = socket.socketpair()
        service = JointFabricService()
        worker = threading.Thread(target=handle_connection, args=(server, service), daemon=True)
        worker.start()
        try:
            get_stream = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["GetStream"], call_id=7)
            client.sendall(encode_frame(get_stream.encode()))
            client.settimeout(0.15)
            with self.assertRaises(socket.timeout):
                client.recv(1024)
            self.assertIn((RPC_CHANNEL, 7), service.streams)

            transfer = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["TransferOwnership"],
                                 b"\x08\x2a\x10\x01\x1a\x41\x04" + bytes(range(64)) + b"\x20\x01",
                                 call_id=9)
            client.sendall(encode_frame(transfer.encode()))
            encoded = client.recv(1024)
            reply = RpcPacket.decode(decode_frame(encoded[1:-1]))
            self.assertEqual(reply.kind, SERVER_ERROR)
            self.assertEqual(reply.status, UNIMPLEMENTED)
            self.assertEqual(reply.call_id, 9)
        finally:
            client.close()
            worker.join(timeout=1)
            server.close()

    def test_jcm_ownership_request_checks_sdk_key_and_endpoint_before_unimplemented(self):
        service = JointFabricService()
        method = METHOD_IDS["TransferOwnership"]
        # OwnershipContext: node_id=42, jcm=true, trustedIcacPublicKeyB=65 bytes,
        # peerAdminJFAdminClusterEndpointId=1. SDK JFA checks the two fields.
        prefix = b"\x08\x2a\x10\x01"
        valid_key = b"\x1a\x41\x04" + bytes(range(64))
        request = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, method,
                            prefix + valid_key + b"\x20\x01", call_id=11)
        self.assertEqual(service.handle(request).status, UNIMPLEMENTED)
        self.assertEqual(service.handle(RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, method,
                                                  prefix + b"\x1a\x01\x04" + b"\x20\x01")).status,
                         OUT_OF_RANGE)
        self.assertEqual(service.handle(RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, method,
                                                  prefix + b"\x1a\x41" + bytes(range(65)) + b"\x20\x01")).status,
                         OUT_OF_RANGE)
        self.assertEqual(service.handle(RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, method,
                                                  prefix + valid_key + b"\x20\xff\xff\x03")).status,
                         OUT_OF_RANGE)
        self.assertEqual(service.handle(RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, method,
                                                  prefix + valid_key + b"\x20\x80\x80\x04")).status,
                         OUT_OF_RANGE)
        self.assertEqual(service.handle(RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, method,
                                                  b"\x08\x2a\x10\x02" + valid_key + b"\x20\x01")).status,
                         OUT_OF_RANGE)
        self.assertEqual(service.handle(RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, method,
                                                  b"\x08\x2a")).status, UNIMPLEMENTED)

    def test_icac_csr_response_stream_is_explicitly_unimplemented(self):
        service = JointFabricService()
        # Response(transaction_type=ICAC_CSR, response_bytes=<DER CSR>).
        request = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["ResponseStream"],
                            b"\x12\x03\x30\x01\x00", call_id=12)
        reply = service.handle(request)
        self.assertEqual(reply.kind, SERVER_ERROR)
        self.assertEqual(reply.status, UNIMPLEMENTED)
        self.assertEqual(reply.call_id, 12)

    def test_icac_csr_single_flight_stream_and_bound_result(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "csr.json"
            root = b"\x04" + bytes(range(64))
            mailbox = CsrMailbox(path, 41216, root)
            service = JointFabricService(csr_mailbox=mailbox)
            stream = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["GetStream"], call_id=17)
            self.assertIsNone(service.handle(stream))
            path.write_text(json.dumps({"operation": "icac-csr", "fabric_id": 41216,
                                        "root_public_key": root.hex(), "nonce": "a" * 32}))
            outbound = service.poll_stream()
            self.assertEqual(outbound.kind, SERVER_STREAM)
            self.assertEqual(outbound.call_id, 17)
            self.assertEqual(outbound.payload, b"\x08\x00\x10\x80\xc2\x02")
            self.assertIsNone(service.poll_stream())
            csr = b"\x30\x03\x02\x01\x00"
            response = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["ResponseStream"],
                                 b"\x08\x00\x12\x05" + csr, call_id=18)
            self.assertEqual(service.handle(response).kind, RESPONSE)
            self.assertEqual(json.loads(path.read_text()),
                             {"nonce": "a" * 32, "status": "ok", "csr": base64.b64encode(csr).decode()})
            self.assertEqual(service.handle(response).status, FAILED_PRECONDITION)
            path.write_text(json.dumps({"operation": "icac-csr", "fabric_id": 41216,
                                        "root_public_key": root.hex(), "nonce": "b" * 32}))
            self.assertIsNone(service.poll_stream())
            self.assertEqual(json.loads(path.read_text())["status"], "stream-consumed")

    def test_csr_timeout_wrong_fabric_and_disconnect_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "csr.json"
            root = b"\x04" + bytes(range(64))
            mailbox = CsrMailbox(path, 41216, root, timeout=0.01)
            service = JointFabricService(csr_mailbox=mailbox)
            path.write_text(json.dumps({"operation": "icac-csr", "fabric_id": 7,
                                        "root_public_key": root.hex(), "nonce": "a" * 32}))
            self.assertIsNone(service.poll_stream())
            self.assertEqual(json.loads(path.read_text())["status"], "wrong-fabric")
            path.write_text(json.dumps({"operation": "icac-csr", "fabric_id": 41216,
                                        "root_public_key": root.hex(), "nonce": "b" * 32}))
            self.assertIsNone(service.poll_stream())
            self.assertEqual(json.loads(path.read_text())["status"], "unavailable")
            service.handle(RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["GetStream"], call_id=21))
            path.write_text(json.dumps({"operation": "icac-csr", "fabric_id": 41216,
                                        "root_public_key": root.hex(), "nonce": "c" * 32}))
            self.assertEqual(service.poll_stream().kind, SERVER_STREAM)
            with mock.patch("joint_fabric_rpc_bridge.time.monotonic", return_value=mailbox.deadline + 1):
                service.poll_stream()
            self.assertEqual(json.loads(path.read_text())["status"], "timeout")
            service.disconnect()
            self.assertFalse(service.streams)

    def test_new_sdk_fabric_can_supply_its_selector_after_anchor_commissioning(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "csr.json"
            mailbox = CsrMailbox(path)
            service = JointFabricService(csr_mailbox=mailbox)
            service.handle(RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["GetStream"], call_id=8))
            root = b"\x04" + bytes(range(64))
            path.write_text(json.dumps({"operation": "icac-csr", "fabric_id": 41216,
                                        "root_public_key": root.hex(), "nonce": "e" * 32}))
            outbound = service.poll_stream()
            self.assertEqual(outbound.kind, SERVER_STREAM)
            self.assertEqual(outbound.payload, b"\x08\x00\x10\x80\xc2\x02")
            service.disconnect()
            self.assertEqual(json.loads(path.read_text())["status"], "unavailable")

    def test_csr_exchange_over_hdlc_socket_and_reconnect(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "csr.json"
            root = b"\x04" + bytes(range(64))
            mailbox = CsrMailbox(path, 41216, root)
            service = JointFabricService(csr_mailbox=mailbox)
            client, server = socket.socketpair()
            worker = threading.Thread(target=handle_connection, args=(server, service), daemon=True)
            worker.start()
            try:
                get_stream = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["GetStream"], call_id=23)
                client.sendall(encode_frame(get_stream.encode()))
                deadline = time.monotonic() + 1
                while (RPC_CHANNEL, 23) not in service.streams and time.monotonic() < deadline:
                    time.sleep(0.005)
                self.assertIn((RPC_CHANNEL, 23), service.streams)
                path.write_text(json.dumps({"operation": "icac-csr", "fabric_id": 41216,
                                            "root_public_key": root.hex(), "nonce": "d" * 32}))
                client.settimeout(1)
                stream = RpcPacket.decode(decode_frame(client.recv(2048)[1:-1]))
                self.assertEqual(stream.kind, SERVER_STREAM)
                self.assertEqual(stream.call_id, 23)
                response = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["ResponseStream"],
                                     b"\x12\x05\x30\x03\x02\x01\x00", call_id=24)
                client.sendall(encode_frame(response.encode()))
                reply = RpcPacket.decode(decode_frame(client.recv(2048)[1:-1]))
                self.assertEqual(reply.kind, RESPONSE)
                self.assertEqual(json.loads(path.read_text())["nonce"], "d" * 32)
            finally:
                client.close()
                worker.join(timeout=1)
                server.close()
            self.assertFalse(service.streams)

    def test_standard_handoff_is_durably_queued_before_rpc_ack(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "jfa-command.yml"
            queue = HandoffQueue(path, 41216, b"\x04" + bytes(range(64)))
            service = JointFabricService(handoff=queue)
            request = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["TransferOwnership"],
                                b"\x08\x2a", call_id=13)
            with mock.patch("os.fsync", wraps=os.fsync) as sync:
                reply = service.handle(request)
            self.assertEqual(sync.call_count, 2)
            self.assertEqual(reply.kind, RESPONSE)
            self.assertEqual(reply.call_id, 13)
            content = path.read_text(encoding="utf-8")
            self.assertIn('operation: "finalize-commissioning"', content)
            self.assertIn("node_id: 42", content)
            self.assertIn("fabric_id: 41216", content)
            self.assertIn("jcm: false", content)
            self.assertIn("root_public_key: !!binary ", content)
            self.assertRegex(content, r'nonce: "[0-9a-f]{32}"')
            self.assertEqual(service.handle(request).status, FAILED_PRECONDITION)

    def test_jcm_handoff_queues_bound_public_key_and_endpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "jfa-command.yml"
            queue = HandoffQueue(path, 41216, b"\x04" + bytes(range(64)))
            service = JointFabricService(handoff=queue)
            trusted_key = b"\x04" + bytes(reversed(range(64)))
            payload = b"\x08\x2a\x10\x01\x1a\x41" + trusted_key + b"\x20\x01"
            request = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["TransferOwnership"],
                                payload, call_id=14)
            invalid = RpcPacket(REQUEST, RPC_CHANNEL, SERVICE_ID, METHOD_IDS["TransferOwnership"],
                                b"\x08\x2a\x10\x01\x1a\x41" + bytes(range(65)) + b"\x20\x01")
            self.assertEqual(service.handle(invalid).status, OUT_OF_RANGE)
            self.assertFalse(path.exists())
            reply = service.handle(request)
            self.assertEqual(reply.kind, RESPONSE)
            self.assertEqual(reply.call_id, 14)
            content = path.read_text(encoding="utf-8")
            self.assertIn("jcm: true", content)
            self.assertIn("peer_admin_jfa_endpoint_id: 1", content)
            self.assertIn("trusted_icac_public_key_b: !!binary ", content)
            encoded = content.split("trusted_icac_public_key_b: !!binary ", 1)[1].splitlines()[0]
            self.assertEqual(base64.b64decode(encoded), trusted_key)


if __name__ == "__main__":
    unittest.main()
