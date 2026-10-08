#!/usr/bin/env python3
"""Speak just enough of the Luanti 5.17 handshake to deliver a player name.

The server calls the prejoin allowlist while handling TOSERVER_INIT, before
authentication. This client does not complete SRP. Success is the server log,
not a finished login.
"""

import socket
import struct
import sys
import time

PROTOCOL_ID = 0x4F457403
SEQ_INITIAL = 65500
TYPE_CONTROL = 0
TYPE_ORIGINAL = 1
TYPE_RELIABLE = 3
CONTROL_ACK = 0
CONTROL_SET_PEER_ID = 1
SER_FMT = 29
PROTO_MIN = 37
PROTO_MAX = 53


def header(peer, payload):
    return struct.pack(">IHB", PROTOCOL_ID, peer, 0) + payload


def reliable(peer, seq, inner):
    return header(peer, struct.pack(">BH", TYPE_RELIABLE, seq & 0xFFFF) + inner)


def original(payload):
    return bytes([TYPE_ORIGINAL]) + payload


def ack(peer, seq):
    return header(peer, bytes([TYPE_CONTROL, CONTROL_ACK]) + struct.pack(">H", seq & 0xFFFF))


def init_packet(name):
    raw = name.encode("utf-8")
    body = struct.pack(">HBHHH", 0x02, SER_FMT, 0, PROTO_MIN, PROTO_MAX)
    body += struct.pack(">H", len(raw)) + raw
    return body


def parse_peer_id(packet):
    """Return (peer_id or None, reliable seq or None)."""
    if len(packet) < 8 or struct.unpack(">I", packet[:4])[0] != PROTOCOL_ID:
        return None, None
    body = packet[7:]
    seq = None
    if body[0] == TYPE_RELIABLE and len(body) >= 3:
        seq = struct.unpack(">H", body[1:3])[0]
        body = body[3:]
    if len(body) >= 4 and body[0] == TYPE_CONTROL and body[1] == CONTROL_SET_PEER_ID:
        return struct.unpack(">H", body[2:4])[0], seq
    return None, seq


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: luanti_probe.py host port playername")
    host, port, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.5)
    dest = (host, port)
    connect = reliable(0, SEQ_INITIAL, original(b""))
    peer = None
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and peer is None:
        sock.sendto(connect, dest)
        while time.monotonic() < deadline:
            try:
                packet, _ = sock.recvfrom(4096)
            except socket.timeout:
                break
            found, seq = parse_peer_id(packet)
            if seq is not None and found is not None:
                sock.sendto(ack(0, seq), dest)
            if found:
                peer = found
                break
    if peer is None:
        sys.exit("did not receive a peer id")
    seq = (SEQ_INITIAL + 1) & 0xFFFF
    message = reliable(peer, seq, original(init_packet(name)))
    end = time.monotonic() + 4
    while time.monotonic() < end:
        sock.sendto(message, dest)
        try:
            packet, _ = sock.recvfrom(4096)
        except socket.timeout:
            continue
        if len(packet) >= 10 and packet[7] == TYPE_RELIABLE:
            their_seq = struct.unpack(">H", packet[8:10])[0]
            sock.sendto(ack(peer, their_seq), dest)
        time.sleep(0.2)
    print(f"sent TOSERVER_INIT for {name} as peer {peer}")


if __name__ == "__main__":
    main()
