#!/usr/bin/env bash
# Check each CLAUDE_AUTH mode end to end on the actor side, without a cluster:
# Claude Code runs with exactly the placeholder the ActorTemplate gives it, and
# a stand-in for substrate's egress gateway (TLS for every host Claude Code
# might call) records each request. Per mode, every credential Claude Code
# sends must be in the header the rendered egress policy replaces, never in
# the other one, and only to the hosts that policy allows.
#
# The stand-in answers 401, so this checks what reaches the gateway, not a
# real model call; `host/herdr-substrate.sh verify` does that on a cluster.
#
# Needs: docker, python3 with PyYAML, openssl, and an image with Claude Code
# and python3 (default: the actor image). Usage:
#   test/claude-auth-test.sh [IMAGE]
# CLAUDE_DIR=/path mounts a Claude Code install over the image's (it must hold
# bin/claude), for an image without one.
# shellcheck disable=SC2015 # "check && ok || bad" is safe: ok and bad always succeed
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-herdr-actor:dev}"
NAME="claude-auth-test-$$"
NET="${NAME}"
WORK="$(mktemp -d)"
GW_IP=10.231.0.10
pass=0 fail=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

cleanup() {
  docker rm -f "${NAME}-gw" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  if [[ "${KEEP:-0}" == 1 ]]; then echo "kept ${WORK}"; else rm -rf "${WORK}"; fi
}
trap cleanup EXIT

# Every host Claude Code's documentation lists, so a call to any of them is
# recorded rather than failing on DNS (code.claude.com/docs/en/network-config).
HOSTS=(api.anthropic.com claude.ai claude.com platform.claude.com sso.claude.com
       mcp-proxy.anthropic.com downloads.claude.ai storage.googleapis.com registry.npmjs.org
       raw.githubusercontent.com http-intake.logs.us5.datadoghq.com
       browser-intake-us5-datadoghq.com code.claude.com statsig.anthropic.com)

# --- gateway stand-in: one CA, one certificate for every host
cd "${WORK}"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=egress-mitm-test" \
  -keyout ca.key -out ca.crt -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=gateway" -keyout gw.key -out gw.csr 2>/dev/null
san="$(printf 'DNS:%s,' "${HOSTS[@]}")"
printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "${san%,}" >gw.ext
openssl x509 -req -in gw.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile gw.ext -out gw.crt 2>/dev/null
cat >gw.py <<'PY'
import http.server, json, ssl
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def handle_any(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        print(json.dumps({"host": (self.headers.get("host") or "").split(":")[0],
                          "path": self.path.split("?")[0],
                          "authorization": self.headers.get("authorization"),
                          "x-api-key": self.headers.get("x-api-key")}), flush=True)
        out = b'{"type":"error","error":{"type":"authentication_error","message":"gateway stand-in"}}'
        self.send_response(401); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out))); self.end_headers(); self.wfile.write(out)
    do_GET = do_POST = do_PUT = do_HEAD = do_DELETE = handle_any
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain("gw.crt", "gw.key")
s = http.server.ThreadingHTTPServer(("0.0.0.0", 443), H)
s.socket = ctx.wrap_socket(s.socket, server_side=True)
s.serve_forever()
PY
docker network create --internal --subnet 10.231.0.0/24 "${NET}" >/dev/null
docker run -d --name "${NAME}-gw" --network "${NET}" --ip "${GW_IP}" -v "${WORK}:/gw:ro" -w /gw \
  --entrypoint python3 "${IMAGE}" -u gw.py >/dev/null

add_hosts=(); for h in "${HOSTS[@]}"; do add_hosts+=(--add-host "${h}:${GW_IP}"); done
mounts=(); claude=claude
if [[ -n "${CLAUDE_DIR:-}" ]]; then mounts=(-v "${CLAUDE_DIR}:/opt/claude-test:ro"); claude=/opt/claude-test/bin/claude; fi

for mode in api-key oauth-token; do
  step "CLAUDE_AUTH=${mode}"
  # The script's own settings and policy rendering, as `deploy` and `actor` use them.
  # shellcheck disable=SC1091,SC2016
  CLAUDE_AUTH="${mode}" bash -c 'source "$1/host/herdr-substrate.sh"
    render_egress_policy "$2/policy-$3.yaml"
    printf "%s=%s\n" "${CLAUDE_AUTH_ENV}" "${CLAUDE_AUTH_PLACEHOLDER}" >"$2/env-$3"' _ "${KIT_DIR}" "${WORK}" "${mode}"
  IFS=$'\t' read -r header prefix hosts < <(python3 - "${WORK}/policy-${mode}.yaml" <<'PY'
import sys, yaml
rule = yaml.safe_load(open(sys.argv[1]))["rules"][0]["https"]
inj = rule["effects"]["replaceHeaders"][0]
print(inj["header"].lower(), repr(inj.get("prefix", "")), ",".join(rule["hostnames"]), sep="\t")
PY
)
  ok "policy: replace '${header}' (prefix ${prefix}) for ${hosts}; actor gets $(cut -d= -f1 "${WORK}/env-${mode}")"

  : >"${WORK}/before"; docker logs "${NAME}-gw" >"${WORK}/before" 2>&1
  docker run --rm --network "${NET}" "${add_hosts[@]}" "${mounts[@]}" -v "${WORK}/ca.crt:/ca.crt:ro" \
    --env-file "${WORK}/env-${mode}" -e HOME=/tmp/home -e NODE_EXTRA_CA_CERTS=/ca.crt \
    --entrypoint bash "${IMAGE}" -c '
      mkdir -p /tmp/home /tmp/w && cd /tmp/w
      printf "{\"hasCompletedOnboarding\": true}\n" >/tmp/home/.claude.json
      timeout 120 '"${claude}"' -p "say hi" 2>&1 | tail -n 2' >"${WORK}/claude-${mode}.out" 2>&1 || true
  sleep 1
  docker logs "${NAME}-gw" 2>&1 | tail -n +"$(( $(wc -l <"${WORK}/before") + 1 ))" >"${WORK}/requests-${mode}.jsonl"

  python3 - "${WORK}/requests-${mode}.jsonl" "${header}" "${hosts}" >"${WORK}/verdict-${mode}" <<'PY' || true
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")]
header, allowed = sys.argv[2], set(sys.argv[3].split(","))
other = {"authorization": "x-api-key", "x-api-key": "authorization"}[header]
model = [r for r in reqs if r["path"] == "/v1/messages"]
print(f"requests={len(reqs)}")
print(f"model_requests={len(model)}")
print(f"model_with_header={sum(1 for r in model if r[header])}")
print(f"other_header={sum(1 for r in reqs if r[other])}")
print(f"credentialed={sum(1 for r in reqs if r[header])}")
print(f"outside_hosts={sorted({r['host'] for r in reqs} - allowed)}")
PY
  v() { grep "^$1=" "${WORK}/verdict-${mode}" | cut -d= -f2; }
  [[ "$(v model_requests)" -gt 0 ]] && ok "Claude Code made model requests ($(v requests) requests in all)" \
    || bad "no model request reached the gateway: $(tail -n 2 "${WORK}/claude-${mode}.out")"
  [[ "$(v model_with_header)" == "$(v model_requests)" ]] && ok "every model request carries '${header}', which the gateway replaces" \
    || bad "$(v model_with_header) of $(v model_requests) model requests carry '${header}'"
  [[ "$(v other_header)" == 0 ]] && ok "no request carries the other credential header" \
    || bad "$(v other_header) requests carry the other credential header"
  [[ "$(v outside_hosts)" == "[]" ]] && ok "no request to a host outside the policy" \
    || bad "requests to hosts the policy doesn't allow: $(v outside_hosts)"
done

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
(( fail == 0 ))
