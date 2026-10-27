"""The keeper <-> anchor wire protocol, shared by hub/herdr-keeper and
actor/herdr-anchor. Both images install this file next to their script's
search path (/usr/local/lib/herdr-substrate); in a checkout, each script finds
it in ../common.

Messages, both directions: [u8 type][u32 little-endian length][payload]
    1 HELLO    keeper->anchor  JSON {"v":1,"session":str,"cmd":str|null,"recv":int}
    2 WELCOME  anchor->keeper  JSON {"status":"new"|"resumed"|"unknown","recv":int}
    3 DATA     either way      raw bytes; offsets are implicit
    4 ACK      either way      u64 little-endian: total bytes received so far
    5 CLOSE    keeper->anchor  end the session (the herdr client went away)
    6 END      anchor->keeper  JSON {"reason":str}: the bridge exited

"recv" in HELLO and WELCOME is how many bytes the sender has received from the
other side; each side replays everything past that offset.
"""
import struct

HELLO, WELCOME, DATA, ACK, CLOSE, END = 1, 2, 3, 4, 5, 6
HEADER = struct.Struct("<BI")
_ACK = struct.Struct("<Q")
MAX_MESSAGE = 64 * 1024 * 1024
# Each side acknowledges after this many bytes, so the other can trim its
# replay buffer.
ACK_EVERY = 256 * 1024
PROTOCOL_VERSION = 1


def encode(kind, payload=b""):
    return HEADER.pack(kind, len(payload)) + payload


def encode_ack(received_total):
    return encode(ACK, _ACK.pack(received_total))


def decode_ack(payload):
    (received_total,) = _ACK.unpack(payload)
    return received_total


async def read_message(reader):
    """(kind, payload) of the next message; IncompleteReadError at EOF."""
    header = await reader.readexactly(HEADER.size)
    kind, length = HEADER.unpack(header)
    if length > MAX_MESSAGE:
        raise ValueError(f"message of {length} bytes is too large")
    return kind, await reader.readexactly(length)


class ReplayBuffer:
    """Bytes sent to the peer but not yet acknowledged, kept for replay.

    Offsets count every byte ever appended: `base` is the offset of the oldest
    byte still held, `total` the offset just past the newest.
    """

    def __init__(self):
        self.data = bytearray()
        self.base = 0
        self.total = 0

    def __len__(self):
        return len(self.data)

    def append(self, chunk):
        self.data += chunk
        self.total += len(chunk)

    def holds(self, offset):
        """Whether the peer can resume from `offset`."""
        return self.base <= offset <= self.total

    def trim_to(self, offset):
        """Drop everything before `offset` (the peer has it). False if out of range."""
        if not self.holds(offset):
            return False
        del self.data[: offset - self.base]
        self.base = offset
        return True

    def since(self, offset):
        """The bytes from `offset` (>= base) to the end."""
        return bytes(self.data[offset - self.base:])
