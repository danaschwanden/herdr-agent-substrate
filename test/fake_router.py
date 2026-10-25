#!/usr/bin/env python3
"""Stand-in for substrate's atenet-router, for test/hub-path-test.sh.

Enforces what the real Envoy router enforces on its mTLS listener, as far as
the hub is concerned:
  * TLS with a server certificate for atenet-router.ate-system.svc;
  * a client certificate chained to the podidentity CA whose SPIFFE URI is in
    the allowlist (--allow), like --ingress-allowed-spiffe-ids;
  * routing by the ate-target-actor header to the actor's port 80.
It then relays WebSocket messages both ways. Each accepted request is logged
as "ROUTE <spiffe-id> -> <atespace>/<actor>" so the test can count them.

Needs: pip install websockets
"""
import argparse
import asyncio
import ssl
import sys

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.http11 import Response
from websockets.datastructures import Headers


def peer_spiffe_id(connection):
    ssl_obj = connection.transport.get_extra_info("ssl_object")
    cert = ssl_obj.getpeercert() if ssl_obj else None
    for kind, value in (cert or {}).get("subjectAltName", ()):
        if kind == "URI" and value.startswith("spiffe://"):
            return value
    return None


def deny(status, text):
    body = (text + "\n").encode()
    return Response(status, text, Headers([("Content-Length", str(len(body)))]), body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="127.0.0.1:8443")
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--client-ca", required=True)
    ap.add_argument("--allow", action="append", default=[], help="allowed SPIFFE ID")
    ap.add_argument("--actor", action="append", default=[],
                    help="<atespace>/<actor>=ws://host:port/ backend")
    args = ap.parse_args()

    backends = dict(a.split("=", 1) for a in args.actor)
    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.load_cert_chain(args.cert, args.key)
    ctx.load_verify_locations(args.client_ca)
    ctx.verify_mode = ssl.CERT_REQUIRED

    def check(connection, request):
        spiffe = peer_spiffe_id(connection)
        if spiffe not in args.allow:
            print(f"DENY identity {spiffe}", flush=True)
            return deny(403, "client identity not allowed")
        target = request.headers.get("ate-target-actor", "")
        if target not in backends:
            print(f"DENY target {target!r}", flush=True)
            return deny(404, "unknown actor")
        connection.ate_target = target
        print(f"ROUTE {spiffe} -> {target}", flush=True)
        return None

    async def relay(client):
        target = client.ate_target
        async with connect(backends[target], max_size=None, ping_interval=None) as actor:
            async def pump(src, dst):
                async for message in src:
                    await dst.send(message)
                await dst.close()
            await asyncio.gather(pump(client, actor), pump(actor, client), return_exceptions=True)

    host, port = args.listen.rsplit(":", 1)

    async def run():
        async with serve(relay, host, int(port), ssl=ctx, process_request=check,
                         max_size=None, ping_interval=None):
            print(f"listening on {args.listen}", flush=True)
            await asyncio.Future()

    asyncio.run(run())


if __name__ == "__main__":
    sys.exit(main())
