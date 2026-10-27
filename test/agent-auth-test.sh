#!/usr/bin/env bash
# Check each agent CLI's credential path on the actor side, without a cluster.
#
# For each case (Claude Code with an API key, Claude Code with a subscription
# token, Codex, agy) the test takes the template's placeholder credentials and
# the egress policy exactly as host/herdr-substrate.sh renders them, runs the
# actor's own agent-setup, then runs the CLI once. A stand-in for substrate's
# egress gateway (TLS for every host the CLIs might call, trusted the way the
# actor trusts the real one) records each request. It checks:
#   - the CLI reaches the host its egress rule allows;
#   - every request to that host carries the placeholder in the header the
#     rule replaces, so the gateway can inject the real credential;
#   - no request to that host carries it anywhere else.
# Other hosts a CLI tries are listed; in an actor, default-deny egress blocks them.
#
# The stand-in answers 401, so this checks what reaches the gateway, not a real
# model call; `host/herdr-substrate.sh verify` does that on a cluster.
#
# Needs docker, python3 with PyYAML, openssl, and an image with the CLIs and
# python3 (default: the actor image). A CLI missing from the image is skipped.
#   test/agent-auth-test.sh [IMAGE]
# TEST_BIN_DIRS="dir1:dir2" mounts host directories (read-only, same paths) and
# puts them first on PATH, for an image without the CLIs; symlinks in them may
# point into other directories listed there.
# shellcheck disable=SC2015 # "check && ok || bad" is safe: ok and bad always succeed
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-herdr-actor:dev}"
NAME="agent-auth-test-$$"
WORK="$(mktemp -d)"
GW_IP=10.231.0.10
pass=0 fail=0 skip=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }
note() { printf '  \033[33mSKIP\033[0m %s\n' "$*"; skip=$((skip + 1)); }
info() { printf '       %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

cleanup() {
  docker rm -f "${NAME}-gw" >/dev/null 2>&1 || true
  docker network rm "${NAME}" >/dev/null 2>&1 || true
  if [[ "${KEEP:-0}" == 1 ]]; then echo "kept ${WORK}"; else rm -rf "${WORK}"; fi
}
trap cleanup EXIT

# Every host the three CLIs are known to call, so each call is recorded
# rather than failing on DNS.
HOSTS=(api.anthropic.com claude.ai claude.com platform.claude.com sso.claude.com
       mcp-proxy.anthropic.com downloads.claude.ai storage.googleapis.com registry.npmjs.org
       raw.githubusercontent.com http-intake.logs.us5.datadoghq.com
       browser-intake-us5-datadoghq.com code.claude.com statsig.anthropic.com
       api.openai.com chatgpt.com ab.chatgpt.com auth.openai.com github.com
       generativelanguage.googleapis.com oauth2.googleapis.com aiplatform.googleapis.com
       cloudcode-pa.googleapis.com play.googleapis.com antigravity.google)

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
                          "path": self.path.split("?")[0], "query": "?" in self.path,
                          "headers": {k.lower(): v for k, v in self.headers.items()}}), flush=True)
        out = b'{"type":"error","error":{"type":"authentication_error","message":"gateway stand-in"}}'
        self.send_response(401); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out))); self.end_headers(); self.wfile.write(out)
    do_GET = do_POST = do_PUT = do_HEAD = do_DELETE = handle_any
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain("gw.crt", "gw.key")
s = http.server.ThreadingHTTPServer(("0.0.0.0", 443), H)
s.socket = ctx.wrap_socket(s.socket, server_side=True)
s.serve_forever()
PY
docker network create --internal --subnet 10.231.0.0/24 "${NAME}" >/dev/null
docker run -d --name "${NAME}-gw" --network "${NAME}" --ip "${GW_IP}" -v "${WORK}:/gw:ro" -w /gw \
  --entrypoint python3 "${IMAGE}" -u gw.py >/dev/null

add_hosts=(); for h in "${HOSTS[@]}"; do add_hosts+=(--add-host "${h}:${GW_IP}"); done
mounts=() path_prefix=""
IFS=':' read -r -a bin_dirs <<<"${TEST_BIN_DIRS:-}"
for d in "${bin_dirs[@]}"; do [[ -n "${d}" ]] && mounts+=(-v "${d}:${d}:ro") && path_prefix+="${d}:"; done

# case: label, AGENTS, CLAUDE_AUTH, CLI binary, its one-shot command
run_case() {
  local label="$1" agents="$2" auth="$3" cli="$4" cmd="$5"
  step "${label}"
  if ! docker run --rm "${mounts[@]}" -e PATH="${path_prefix}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      --entrypoint sh "${IMAGE}" -c "command -v ${cli}" >/dev/null 2>&1; then
    note "${cli} is not in ${IMAGE}"
    return
  fi
  # The script's own rendering, as `deploy`, `actor` and `hub` use it.
  # shellcheck disable=SC2016
  AGENTS="${agents}" CLAUDE_AUTH="${auth}" bash -c 'source "$1/host/herdr-substrate.sh"
    render_egress_policy "$2/policy.yaml"
    agent_env_yaml >"$2/env.yaml"' _ "${KIT_DIR}" "${WORK}"
  python3 - "${WORK}/env.yaml" >"${WORK}/env" <<'PY'
import sys, yaml
for e in yaml.safe_load(open(sys.argv[1])):
    print(f"{e['name']}={e['value']}")
PY
  read -r host header placeholder < <(python3 - "${WORK}/policy.yaml" "${WORK}/env" <<'PY'
import sys, yaml
rule = yaml.safe_load(open(sys.argv[1]))["rules"][-1]["https"]
env = dict(l.strip().split("=", 1) for l in open(sys.argv[2]) if "=" in l)
print(rule["hostnames"][0], rule["effects"]["replaceHeaders"][0]["header"].lower(), list(env.values())[-1])
PY
)
  ok "rendered: ${host} replaces '${header}'; actor gets $(cut -d= -f1 "${WORK}/env" | tr '\n' ' ')"

  docker logs "${NAME}-gw" >"${WORK}/before" 2>&1
  docker run --rm --network "${NAME}" "${add_hosts[@]}" "${mounts[@]}" \
    -v "${WORK}/ca.crt:/run/ate/trust-bundle.pem:ro" -v "${KIT_DIR}/actor/agent-setup:/opt/test/agent-setup:ro" \
    --env-file "${WORK}/env" -e HOME=/tmp/home -e NODE_EXTRA_CA_CERTS=/run/ate/trust-bundle.pem \
    -e PATH="${path_prefix}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --entrypoint bash "${IMAGE}" -c '
      mkdir -p /usr/local/share/ca-certificates /tmp/home/.codex /tmp/home/.gemini /tmp/w && cd /tmp/w
      cp /run/ate/trust-bundle.pem /usr/local/share/ca-certificates/ate-egress-mitm.crt && update-ca-certificates >/dev/null 2>&1
      printf "{\"hasCompletedOnboarding\": true}\n" >/tmp/home/.claude.json
      bash /opt/test/agent-setup
      timeout 120 '"${cmd}"' </dev/null 2>&1 | tail -n 3' >"${WORK}/cli.out" 2>&1 || true
  sleep 1
  docker logs "${NAME}-gw" 2>&1 | tail -n +"$(( $(wc -l <"${WORK}/before") + 1 ))" >"${WORK}/requests.jsonl"

  python3 - "${WORK}/requests.jsonl" "${host}" "${header}" "${placeholder}" >"${WORK}/verdict" <<'PY' || true
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")]
host, header, ph = sys.argv[2:5]
to_host = [r for r in reqs if r["host"] == host]
carrying = [r for r in to_host if ph in (r["headers"].get(header) or "")]
elsewhere = [r for r in to_host if any(ph in v for k, v in r["headers"].items() if k != header)]
others = sorted({r["host"] for r in reqs if r["host"] != host})
print(f"total={len(reqs)}")
print(f"to_host={len(to_host)}")
print(f"carrying={len(carrying)}")
print(f"credentialed_paths={sorted({r['path'] for r in carrying})[:4]}")
print(f"elsewhere={len(elsewhere)}")
print(f"others={others}")
PY
  v() { grep "^$1=" "${WORK}/verdict" | cut -d= -f2-; }
  if [[ "$(v to_host)" -gt 0 ]]; then
    ok "${cli} reached ${host} ($(v to_host) of $(v total) requests)"
  else
    bad "${cli} never reached ${host}: $(tail -n 3 "${WORK}/cli.out" | tr '\n' ' ')"; return
  fi
  [[ "$(v carrying)" -gt 0 ]] && ok "it sends the placeholder in '${header}', which the gateway replaces: $(v credentialed_paths)" \
    || bad "no request to ${host} carries the placeholder in '${header}'"
  [[ "$(v elsewhere)" == 0 ]] && ok "never in any other header" || bad "$(v elsewhere) requests carry it in another header"
  [[ "$(v others)" == "[]" ]] || info "also tried (blocked by default-deny in an actor): $(v others)"
}

run_case "Claude Code, CLAUDE_AUTH=api-key" claude api-key claude 'claude -p "say hi"'
run_case "Claude Code, CLAUDE_AUTH=oauth-token" claude oauth-token claude 'claude -p "say hi"'
run_case "Codex (OPENAI_API_KEY)" codex api-key codex 'codex exec --skip-git-repo-check "say hi"'
run_case "Antigravity CLI (GEMINI_API_KEY)" agy api-key agy 'agy -p "say hi"'

printf '\n%d passed, %d failed, %d skipped\n' "${pass}" "${fail}" "${skip}"
(( fail == 0 ))
