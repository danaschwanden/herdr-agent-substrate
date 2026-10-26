#!/usr/bin/env python3
"""Keeper <-> anchor test, no containers needed.

Runs hub/herdr-keeper and actor/herdr-anchor for real, with stand-ins for
the two things around them:
  * the herdr server: a bridge that answers health pings like herdr does and
    echoes every other frame back with a sequence number;
  * SSH to the actor: a fake `ssh` that runs `herdr-anchor attach` locally.
"Suspending the actor" is SIGSTOP on the anchor (its processes freeze, its
connections stay); the fake ssh sends SIGCONT first, the way substrate's
router resumes an actor when a connection arrives. The test plays the herdr
client on the keeper's stdin/stdout.

Usage: test/keeper-test.py
"""
import asyncio
import json
import os
import random
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARKER = "HERDR_TEST_READY_7f3a"
PING = b"endpoint.health.ping.v1"
PONG = b"endpoint.health.pong.v1"
passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"  \033[32mPASS\033[0m {msg}", flush=True)


def bad(msg):
    global failed
    failed += 1
    print(f"  \033[31mFAIL\033[0m {msg}", flush=True)


def check(cond, msg, detail=""):
    ok(msg) if cond else bad(f"{msg} {detail}")


def frame(payload):
    return struct.pack("<I", len(payload)) + payload


def control(kind, data=b""):
    return bytes([20, len(kind)]) + kind + bytes([len(data)]) + data


FAKE_BRIDGE = r'''
import os, struct, sys
PING = b"endpoint.health.ping.v1"; PONG = b"endpoint.health.pong.v1"
inp, out = sys.stdin.buffer, sys.stdout.buffer
seq = pings = 0
def read(n):
    b = b""
    while len(b) < n:
        c = inp.read(n - len(b))
        if not c: sys.exit(0)
        b += c
    return b
while True:
    (n,) = struct.unpack("<I", read(4)); p = read(n)
    if p[:1] == b"\x14" and p[2:2 + p[1]] == PING:
        pings += 1
        data = p[3 + p[1]:]
        r = b"\x14" + bytes([len(PONG)]) + PONG + bytes([len(data)]) + data
    else:
        seq += 1
        r = b"\x63" + struct.pack("<II", seq, pings) + p
    out.write(struct.pack("<I", len(r)) + r); out.flush()
'''


class Client:
    """Plays the herdr client on the keeper's stdio."""

    def __init__(self, proc):
        self.proc = proc
        self.buf = b""

    async def read_exact(self, n, timeout):
        while len(self.buf) < n:
            chunk = await asyncio.wait_for(self.proc.stdout.read(65536), timeout)
            if not chunk:
                raise EOFError("keeper closed stdout")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    async def preamble(self, timeout=20):
        want = ("\n" + MARKER + "\n").encode()
        got = await self.read_exact(len(want), timeout)
        return got == want

    async def recv(self, timeout=20):
        (n,) = struct.unpack("<I", await self.read_exact(4, timeout))
        return await self.read_exact(n, timeout)

    async def send(self, payload):
        self.proc.stdin.write(frame(payload))
        await self.proc.stdin.drain()


def keeper_call(run, request, timeout=40):
    import glob
    socks = glob.glob(os.path.join(run, "luna", "*.sock"))
    assert socks, "no keeper control socket"
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(timeout)
    s.connect(socks[0])
    s.sendall(json.dumps(request).encode() + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        data += s.recv(65536)
    return json.loads(data)


async def main():
    work = tempfile.mkdtemp(prefix="keeper-test-")
    run = os.path.join(work, "run")
    sock = os.path.join(work, "anchor.sock")
    bridge = os.path.join(work, "fake_bridge.py")
    open(bridge, "w").write(FAKE_BRIDGE)
    pidfile = os.path.join(work, "anchor.pid")
    fake_ssh = os.path.join(work, "ssh")
    open(fake_ssh, "w").write(
        "#!/bin/sh\n"
        f"kill -CONT $(cat {pidfile}) 2>/dev/null\n"
        f"echo connect >>{work}/ssh.log\n"
        f"exec python3 {KIT}/actor/herdr-anchor --socket {sock} attach\n")
    os.chmod(fake_ssh, 0o755)

    def start_anchor():
        p = subprocess.Popen([sys.executable, f"{KIT}/actor/herdr-anchor", "--socket", sock, "serve"],
                             stderr=open(os.path.join(work, "anchor.log"), "a"),
                             env={**os.environ, "HERDR_ANCHOR_DETACHED_TTL": "900"})
        open(pidfile, "w").write(str(p.pid))
        for _ in range(50):
            if os.path.exists(sock):
                break
            time.sleep(0.1)
        return p

    anchor = start_anchor()
    cmd = f"printf '\n%s\n' '{MARKER}'\nexec python3 {bridge} --idle-timeout-v1"
    env = {**os.environ, "HERDR_REAL_SSH": fake_ssh, "HERDR_KEEPER_RUN": run, "HOME": work,
           "HERDR_KEEPER_WAKE_TIMEOUT": "30"}
    keeper = await asyncio.create_subprocess_exec(
        sys.executable, f"{KIT}/hub/herdr-keeper", "--target", "ate-luna", "--command", cmd,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        env=env)
    client = Client(keeper)
    try:
        print("\n\033[1m1. connect: the bridge's ready marker comes through untouched\033[0m")
        check(await client.preamble(), "ready marker delivered first")
        await client.send(bytes([13]) + b"hello")
        r = await client.recv()
        check(r[:1] == b"\x63" and r.endswith(b"\x0dhello"), "input frame reaches the server and back")

        print("\n\033[1m2. awake: pings go to the real server\033[0m")
        await client.send(control(PING, b"p1"))
        r = await client.recv()
        check(r == control(PONG, b"p1"), "pong echoes the ping's data")
        await client.send(bytes([13]) + b"x")
        r = await client.recv()
        (seq, pings) = struct.unpack("<II", r[1:9])
        check(pings == 1, "server saw the ping", f"(pings={pings})")

        print("\n\033[1m3. park, then suspend the actor\033[0m")
        reply = keeper_call(run, {"cmd": "park", "timeout": 10})
        check(reply.get("result") == "parked", "keeper parked", str(reply))
        os.kill(anchor.pid, signal.SIGSTOP)
        st = keeper_call(run, {"cmd": "status"})
        check(st["state"] == "parked", "status reports parked")

        print("\n\033[1m4. suspended: the client still sees a healthy machine\033[0m")
        t0 = time.monotonic()
        await client.send(control(PING, b"p2"))
        r = await client.recv(timeout=3)
        check(r == control(PONG, b"p2"), f"ping answered locally in {1000 * (time.monotonic() - t0):.0f} ms")
        await client.send(bytes([18, 1]))      # ClientShellFocus: held, no wake
        await client.send(bytes([12]) + b"r1")  # ClientShellResize
        await client.send(bytes([12]) + b"r2")  # newer resize replaces it
        await asyncio.sleep(1.5)
        st = keeper_call(run, {"cmd": "status"})
        check(st["state"] == "parked", "focus and resize frames don't wake the actor")
        check(open(os.path.join(work, "ssh.log")).read().count("connect") == 1, "no reconnect attempted")

        print("\n\033[1m5. a keystroke wakes it; held frames arrive first, in order\033[0m")
        t0 = time.monotonic()
        await client.send(bytes([13]) + b"world")
        got = [await client.recv(timeout=30) for _ in range(3)]
        bodies = [g[9:] for g in got]
        check(bodies == [bytes([12]) + b"r2", bytes([18, 1]), bytes([13]) + b"world"],
              f"resize (latest only), focus, then input; woke in {time.monotonic() - t0:.1f}s", str(bodies))
        seqs = [struct.unpack("<I", g[1:5])[0] for g in got]
        check(seqs == [seq + 1, seq + 2, seq + 3], "same server session: sequence continues", str(seqs))
        check(keeper_call(run, {"cmd": "status"})["state"] == "awake", "status reports awake")

        print("\n\033[1m6. connection drops mid-stream: nothing lost or duplicated\033[0m")
        rng = random.Random(7)
        payloads = [bytes([13]) + rng.randbytes(rng.choice([1, 50, 4000, 70000])) for _ in range(400)]

        async def sender():
            for i, p in enumerate(payloads):
                await client.send(p)
                if i == 150:
                    subprocess.run(["pkill", "-f", f"{sock} attach"])
                if i % 50 == 0:
                    await asyncio.sleep(0.05)
        connects_before = open(os.path.join(work, "ssh.log")).read().count("connect")
        task = asyncio.create_task(sender())
        received = [(await client.recv(timeout=60))[9:] for _ in payloads]
        await task
        check(received == payloads, f"{len(payloads)} frames ({sum(map(len, payloads)) // 1024} KiB) intact across a forced reconnect")
        connects = open(os.path.join(work, "ssh.log")).read().count("connect") - connects_before
        check(connects >= 1, f"the drop really forced a reconnect ({connects})")
        log = open(os.path.join(work, "anchor.log")).read()
        check(log.count("bridge started") == 1, "the server-side bridge was started exactly once")

        print("\n\033[1m7. park while the client keeps typing: suspend is refused\033[0m")

        async def typing():
            for _ in range(30):
                await client.send(bytes([13]) + b"k")
                await asyncio.sleep(0.1)
        typer = asyncio.create_task(typing())
        await asyncio.sleep(0.2)
        reply = await asyncio.to_thread(keeper_call, run, {"cmd": "park", "timeout": 10})
        await typer
        for _ in range(30):
            await client.recv(timeout=20)
        check(reply.get("result") == "busy", "park answered busy", str(reply))
        check(keeper_call(run, {"cmd": "status"})["state"] == "awake", "still awake afterwards")

        print("\n\033[1m8. the actor lost the session (restart, revert): the client is told\033[0m")
        reply = keeper_call(run, {"cmd": "park", "timeout": 10})
        anchor.kill()
        anchor.wait()
        anchor = start_anchor()
        await client.send(bytes([13]) + b"after-restart")
        try:
            await client.recv(timeout=30)
            bad("expected the keeper to close the connection")
        except EOFError:
            ok("keeper closed the connection, so herdr reconnects normally")
        rc = await asyncio.wait_for(keeper.wait(), 10)
        check(rc == 255, "keeper exited 255, like a failed ssh", f"(rc={rc})")

        print("\n\033[1m9. an actor from an older image (no herdr-anchor): plain relay\033[0m")
        old_ssh = os.path.join(work, "ssh-old")
        open(old_ssh, "w").write(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "cmd = sys.argv[-1]\n"
            "if 'herdr-anchor' in cmd: sys.exit(97)\n"
            "os.execvp('/bin/sh', ['sh', '-c', cmd])\n")
        os.chmod(old_ssh, 0o755)
        old = await asyncio.create_subprocess_exec(
            sys.executable, f"{KIT}/hub/herdr-keeper", "--target", "ate-luna", "--command", cmd,
            "--", "-T", "ate-luna", cmd,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, env={**env, "HERDR_REAL_SSH": old_ssh,
                                                 "HERDR_KEEPER_RUN": run + "-old"})
        oc = Client(old)
        check(await oc.preamble(), "ready marker delivered")
        await oc.send(bytes([13]) + b"legacy")
        r = await oc.recv()
        check(r.endswith(b"\x0dlegacy"), "frames relayed to the server")
        await oc.send(control(PING, b"p9"))
        check(await oc.recv() == control(PONG, b"p9"), "pings answered by the real server")
        import glob
        sock_path = glob.glob(os.path.join(run + "-old", "luna", "*.sock"))[0]
        s2 = socket.socket(socket.AF_UNIX)
        s2.settimeout(10)
        s2.connect(sock_path)
        s2.sendall(b'{"cmd":"park","timeout":5}\n')
        reply = json.loads(s2.recv(65536))
        check(reply.get("result") == "unsupported", "park refused, so hubctl won't suspend it", str(reply))
        old.stdin.close()
        await asyncio.wait_for(old.wait(), 10)
    finally:
        if keeper.returncode is None:
            keeper.kill()
        try:
            os.kill(anchor.pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
        anchor.kill()
    print(f"\n{passed} passed, {failed} failed")
    if failed:
        print(f"logs in {work}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
