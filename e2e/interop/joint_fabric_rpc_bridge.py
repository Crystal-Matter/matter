#!/usr/bin/env python3
"""Test-only Pigweed JointFabric RPC endpoint for the SDK jf-control-app.

This implements the HDLC/pw_rpc transport needed to keep the SDK controller's
GetStream open after commissioning a Crystal Anchor. It can durably queue a
standard (non-JCM) ownership handoff through Crystal JFA's YAML command
channel. The optional fabric probe uses the same channel. JCM handoff and
ICAC CSR streaming remain unsupported.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import logging
import os
import socket
import struct
import threading
import time
import uuid
import zlib
from pathlib import Path


LOG = logging.getLogger("joint_fabric_rpc_bridge")
RPC_ADDRESS = ord("R")
RPC_CHANNEL = 1
FLAG = 0x7E
ESCAPE = 0x7D
REQUEST = 0
RESPONSE = 1
CLIENT_ERROR = 4
SERVER_ERROR = 5
UNIMPLEMENTED = 12
FAILED_PRECONDITION = 9
OUT_OF_RANGE = 11
INTERNAL = 13
MAX_ENCODED_FRAME = 2048
P256_PUBLIC_KEY_LENGTH = 65
INVALID_ENDPOINT_ID = 0xFFFF
MAX_NODE_ID = (1 << 64) - 1


def rpc_id(name: str) -> int:
    """Pigweed's 65599 hash, including the string length seed."""
    value = len(name)
    coefficient = 65599
    for char in name:
        value = (value + coefficient * ord(char)) & 0xFFFFFFFF
        coefficient = (coefficient * 65599) & 0xFFFFFFFF
    return value


SERVICE_ID = rpc_id("JointFabric")
METHOD_IDS = {name: rpc_id(name) for name in ("GetStream", "ResponseStream", "TransferOwnership")}


def varint(value: int) -> bytes:
    if value < 0:
        raise ValueError("negative varint")
    output = bytearray()
    while value > 0x7F:
        output.append((value & 0x7F) | 0x80)
        value >>= 7
    output.append(value)
    return bytes(output)


def read_varint(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    for index in range(10):
        if offset >= len(data):
            raise ValueError("truncated varint")
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << (index * 7)
        if not byte & 0x80:
            return value, offset
    raise ValueError("varint exceeds 64 bits")


def protobuf_fields(data: bytes) -> dict[int, int | bytes]:
    fields: dict[int, int | bytes] = {}
    offset = 0
    while offset < len(data):
        key, offset = read_varint(data, offset)
        number, wire_type = key >> 3, key & 7
        if number == 0:
            raise ValueError("invalid protobuf field zero")
        if wire_type == 0:
            value, offset = read_varint(data, offset)
        elif wire_type == 1:
            value, offset = data[offset : offset + 8], offset + 8
            if len(value) != 8:
                raise ValueError("truncated fixed64")
        elif wire_type == 2:
            length, offset = read_varint(data, offset)
            value, offset = data[offset : offset + length], offset + length
            if len(value) != length:
                raise ValueError("truncated length-delimited field")
        elif wire_type == 5:
            value, offset = data[offset : offset + 4], offset + 4
            if len(value) != 4:
                raise ValueError("truncated fixed32")
        else:
            raise ValueError(f"unsupported protobuf wire type {wire_type}")
        fields[number] = value
    return fields


def _field_varint(number: int, value: int) -> bytes:
    return varint(number << 3) + varint(value)


def _field_fixed32(number: int, value: int) -> bytes:
    return varint((number << 3) | 5) + struct.pack("<I", value)


def _field_bytes(number: int, value: bytes) -> bytes:
    return varint((number << 3) | 2) + varint(len(value)) + value


@dataclasses.dataclass(frozen=True)
class RpcPacket:
    kind: int
    channel_id: int
    service_id: int
    method_id: int
    payload: bytes = b""
    status: int = 0
    call_id: int = 0

    @classmethod
    def decode(cls, data: bytes) -> RpcPacket:
        fields = protobuf_fields(data)

        def integer(number: int) -> int:
            value = fields.get(number, 0)
            if not isinstance(value, int):
                raise ValueError(f"field {number} is not an integer")
            return value

        def fixed32(number: int) -> int:
            value = fields.get(number)
            if not isinstance(value, bytes) or len(value) != 4:
                raise ValueError(f"field {number} is not fixed32")
            return struct.unpack("<I", value)[0]

        payload = fields.get(5, b"")
        if not isinstance(payload, bytes):
            raise ValueError("payload is not bytes")
        return cls(integer(1), integer(2), fixed32(3), fixed32(4), payload, integer(6), integer(7))

    def encode(self) -> bytes:
        fields = bytearray()
        if self.kind:
            fields += _field_varint(1, self.kind)
        fields += _field_varint(2, self.channel_id)
        fields += _field_fixed32(3, self.service_id)
        fields += _field_fixed32(4, self.method_id)
        if self.payload:
            fields += _field_bytes(5, self.payload)
        if self.status:
            fields += _field_varint(6, self.status)
        if self.call_id:
            fields += _field_varint(7, self.call_id)
        return bytes(fields)

    def reply(self, kind: int, status: int = 0, payload: bytes = b"") -> RpcPacket:
        return RpcPacket(kind, self.channel_id, self.service_id, self.method_id, payload, status, self.call_id)


def encode_frame(payload: bytes) -> bytes:
    address = bytearray()
    number = RPC_ADDRESS
    while True:
        address.append((number & 0x7F) << 1)
        number >>= 7
        if not number:
            address[-1] |= 1
            break
    body = bytes(address) + b"\x03" + payload
    body += struct.pack("<I", zlib.crc32(body))
    escaped = body.replace(bytes([ESCAPE]), b"\x7d\x5d").replace(bytes([FLAG]), b"\x7d\x5e")
    return bytes([FLAG]) + escaped + bytes([FLAG])


def decode_frame(encoded: bytes) -> bytes:
    body = bytearray()
    offset = 0
    while offset < len(encoded):
        byte = encoded[offset]
        offset += 1
        if byte == ESCAPE:
            if offset >= len(encoded) or encoded[offset] not in (0x5D, 0x5E):
                raise ValueError("invalid HDLC escape")
            byte = encoded[offset] ^ 0x20
            offset += 1
        body.append(byte)
    if len(body) < 6:
        raise ValueError("short HDLC frame")
    expected_crc = struct.unpack("<I", body[-4:])[0]
    if zlib.crc32(body[:-4]) != expected_crc:
        raise ValueError("HDLC CRC mismatch")
    address = 0
    offset = 0
    while True:
        byte = body[offset]
        address |= (byte >> 1) << (offset * 7)
        offset += 1
        if byte & 1:
            break
        if offset >= len(body) - 5:
            raise ValueError("unterminated HDLC address")
    if address != RPC_ADDRESS or body[offset] != 0x03:
        raise ValueError("unexpected HDLC address or control")
    return bytes(body[offset + 1 : -4])


def frames_from_socket(connection: socket.socket):
    frame = bytearray()
    while chunk := connection.recv(4096):
        for byte in chunk:
            if byte == FLAG:
                if frame:
                    try:
                        yield decode_frame(bytes(frame))
                    except ValueError as error:
                        LOG.warning("Discarded invalid HDLC frame: %s", error)
                    frame.clear()
            elif len(frame) < MAX_ENCODED_FRAME:
                frame.append(byte)
            else:
                frame.clear()


class FabricProbe:
    """Optional read-only Crystal `inspect-fabric` command for a provisioned JFA."""

    def __init__(self, path: Path, fabric_id: int, root_public_key: bytes, timeout: float = 10.0):
        self.path = path
        self.fabric_id = fabric_id
        self.root_public_key = root_public_key
        self.timeout = timeout
        self._lock = threading.Lock()

    def verify(self) -> bool:
        # The command file is single-use: Crystal refuses a second request
        # while a result is present. Give the probe its own file path.
        with self._lock:
            if self.path.exists():
                raise FileExistsError(f"remove the completed command file before probing: {self.path}")
            nonce = uuid.uuid4().hex
            key = base64.b64encode(self.root_public_key).decode("ascii")
            content = (
                "jfa_command:\n  request:\n"
                '    operation: "inspect-fabric"\n'
                "    node_id: 0\n"
                f"    fabric_id: {self.fabric_id}\n"
                f"    root_public_key: !!binary {key}\n"
                f'    nonce: "{nonce}"\n'
            )
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_name(f"{self.path.name}.{nonce}.tmp")
            temporary.write_text(content, encoding="utf-8")
            os.replace(temporary, self.path)

            deadline = time.monotonic() + self.timeout
            while time.monotonic() < deadline:
                # PyYAML is only needed when this optional probe is enabled.
                import yaml  # type: ignore[import-not-found]

                data = yaml.safe_load(self.path.read_text(encoding="utf-8")) or {}
                result = data.get("jfa_command", {}).get("result", {})
                if result and result.get("status") not in (None, "in-progress"):
                    return bool(
                        result.get("status") == "ok"
                        and result.get("fabric_present") is True
                        and result.get("nonce") == nonce
                        and result.get("inspected_fabric_id") == self.fabric_id
                        and result.get("inspected_root_public_key") == self.root_public_key
                    )
                time.sleep(0.1)
            raise TimeoutError("Crystal JFA inspect-fabric command timed out")


class HandoffQueue:
    """Durably queue one commissioning handoff for Crystal JFA."""

    def __init__(self, path: Path, fabric_id: int, root_public_key: bytes):
        if not 0 < fabric_id <= MAX_NODE_ID:
            raise ValueError("fabric ID must be a nonzero uint64")
        if len(root_public_key) != P256_PUBLIC_KEY_LENGTH or root_public_key[0] != 4:
            raise ValueError("root public key must be an uncompressed P-256 point")
        self.path = path
        self.fabric_id = fabric_id
        self.root_public_key = root_public_key
        self._lock = threading.Lock()

    def enqueue(self, node_id: int, jcm: bool = False,
                trusted_icac_public_key_b: bytes | None = None,
                peer_admin_jfa_endpoint_id: int | None = None) -> str:
        if not 0 < node_id <= MAX_NODE_ID:
            raise ValueError("target Node ID must be a nonzero uint64")
        if jcm and (trusted_icac_public_key_b is None
                    or len(trusted_icac_public_key_b) != P256_PUBLIC_KEY_LENGTH
                    or trusted_icac_public_key_b[0] != 4):
            raise ValueError("JCM requires an uncompressed P-256 Administrator ICAC public key")
        if jcm and (peer_admin_jfa_endpoint_id is None
                    or not 0 <= peer_admin_jfa_endpoint_id < INVALID_ENDPOINT_ID):
            raise ValueError("JCM requires a valid peer Administrator endpoint")
        with self._lock:
            if self.path.exists():
                raise FileExistsError(f"Crystal JFA command file already contains a request: {self.path}")
            nonce = uuid.uuid4().hex
            key = base64.b64encode(self.root_public_key).decode("ascii")
            content = (
                "jfa_command:\n  request:\n"
                '    operation: "finalize-commissioning"\n'
                f"    node_id: {node_id}\n"
                f"    fabric_id: {self.fabric_id}\n"
                f"    root_public_key: !!binary {key}\n"
                f'    jcm: {str(jcm).lower()}\n'
                f'    nonce: "{nonce}"\n'
            )
            if jcm:
                trusted_key = base64.b64encode(trusted_icac_public_key_b).decode("ascii")
                content += f"    trusted_icac_public_key_b: !!binary {trusted_key}\n"
                content += f"    peer_admin_jfa_endpoint_id: {peer_admin_jfa_endpoint_id}\n"
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_name(f"{self.path.name}.{nonce}.tmp")
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            descriptor = os.open(temporary, flags, 0o600)
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                    output.write(content)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, self.path)
                directory = os.open(self.path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                temporary.unlink(missing_ok=True)
            LOG.info("Queued Crystal JFA handoff for node 0x%x (jcm=%s, nonce %s)", node_id, jcm, nonce)
            return nonce


class JointFabricService:
    def __init__(self, probe: FabricProbe | None = None, handoff: HandoffQueue | None = None):
        self.probe = probe
        self.handoff = handoff
        self.streams: set[tuple[int, int]] = set()

    def handle(self, request: RpcPacket) -> RpcPacket | None:
        if request.kind == CLIENT_ERROR:
            self.streams.discard((request.channel_id, request.call_id))
            return None
        if request.kind != REQUEST:
            return request.reply(SERVER_ERROR, UNIMPLEMENTED)
        if request.service_id != SERVICE_ID or request.channel_id != RPC_CHANNEL:
            return request.reply(SERVER_ERROR, UNIMPLEMENTED)
        if request.method_id == METHOD_IDS["GetStream"]:
            if request.payload:
                return request.reply(SERVER_ERROR, FAILED_PRECONDITION)
            if self.probe is not None:
                try:
                    if not self.probe.verify():
                        return request.reply(SERVER_ERROR, FAILED_PRECONDITION)
                except Exception as error:
                    LOG.error("Crystal JFA fabric probe failed: %s", error)
                    return request.reply(SERVER_ERROR, INTERNAL)
            self.streams.add((request.channel_id, request.call_id))
            LOG.info("SDK JFC GetStream opened (call %d)", request.call_id)
            return None  # Server-streaming RPC remains active.
        if request.method_id == METHOD_IDS["TransferOwnership"]:
            fields = protobuf_fields(request.payload)
            jcm = fields.get(2, 0)
            public_key = fields.get(3, b"")
            endpoint = fields.get(4, 0)
            if not isinstance(jcm, int) or jcm not in (0, 1):
                return request.reply(SERVER_ERROR, OUT_OF_RANGE)
            if jcm and (not isinstance(public_key, bytes)
                        or len(public_key) != P256_PUBLIC_KEY_LENGTH
                        or public_key[0] != 4):
                return request.reply(SERVER_ERROR, OUT_OF_RANGE)
            if jcm and (not isinstance(endpoint, int) or not 0 <= endpoint < INVALID_ENDPOINT_ID):
                return request.reply(SERVER_ERROR, OUT_OF_RANGE)
            if self.handoff is not None:
                node_id = fields.get(1)
                if not isinstance(node_id, int) or not 0 < node_id <= MAX_NODE_ID:
                    return request.reply(SERVER_ERROR, OUT_OF_RANGE)
                try:
                    self.handoff.enqueue(node_id, bool(jcm), public_key if jcm else None,
                                         endpoint if jcm else None)
                except FileExistsError as error:
                    LOG.error("Crystal JFA handoff queue is busy: %s", error)
                    return request.reply(SERVER_ERROR, FAILED_PRECONDITION)
                except OSError as error:
                    LOG.error("Could not durably queue Crystal JFA handoff: %s", error)
                    return request.reply(SERVER_ERROR, INTERNAL)
                return request.reply(RESPONSE)
            LOG.warning(
                "SDK ownership handoff unavailable (node_id=%s, jcm=%s); Crystal has no matching headless operation",
                fields.get(1), jcm,
            )
            return request.reply(SERVER_ERROR, UNIMPLEMENTED)
        if request.method_id == METHOD_IDS["ResponseStream"]:
            LOG.warning("SDK ResponseStream unavailable without an ICAC request stream")
            return request.reply(SERVER_ERROR, UNIMPLEMENTED)
        return request.reply(SERVER_ERROR, UNIMPLEMENTED)


def serve(host: str, port: int, probe: FabricProbe | None = None,
          handoff: HandoffQueue | None = None) -> None:
    with socket.create_server((host, port), reuse_port=False) as server:
        LOG.info("Listening for SDK jfc-app Pigweed RPC on %s:%d", host, port)
        while True:
            connection, address = server.accept()
            LOG.info("SDK JFC connected from %s", address)
            with connection:
                handle_connection(connection, JointFabricService(probe, handoff))


def handle_connection(connection: socket.socket, service: JointFabricService) -> None:
    for data in frames_from_socket(connection):
        try:
            request = RpcPacket.decode(data)
            response = service.handle(request)
        except (ValueError, struct.error) as error:
            LOG.warning("Discarded malformed RPC request: %s", error)
            continue
        if response is not None:
            connection.sendall(encode_frame(response.encode()))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=33000)
    parser.add_argument("--command-path", type=Path)
    parser.add_argument("--handoff-command-path", type=Path)
    parser.add_argument("--fabric-id", type=int)
    parser.add_argument("--root-public-key-hex")
    args = parser.parse_args()
    probe = None
    handoff = None
    if args.command_path or args.handoff_command_path:
        if args.fabric_id is None or args.root_public_key_hex is None:
            parser.error("--fabric-id and --root-public-key-hex are required for Crystal command paths")
        root_public_key = bytes.fromhex(args.root_public_key_hex)
        if args.command_path:
            probe = FabricProbe(args.command_path, args.fabric_id, root_public_key)
        if args.handoff_command_path:
            handoff = HandoffQueue(args.handoff_command_path, args.fabric_id, root_public_key)
        if args.command_path == args.handoff_command_path:
            parser.error("probe and handoff command paths must be distinct")
    elif args.fabric_id is not None or args.root_public_key_hex is not None:
        parser.error("a Crystal command path is required with fabric identity")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    serve(args.host, args.port, probe, handoff)


if __name__ == "__main__":
    main()
