#!/usr/bin/env bash
# Exercise the hub without a cluster:
#
#   hub/entrypoint.sh + hubctl + ate-wss-proxy (run natively, throwaway HOME)
#     -> wss:// with a SPIFFE client cert -> test/fake_router.py (enforces the
#        allowlist and ate-target-actor, like atenet-router's mTLS listener)
#     -> actor container (actor image, substrate's capability set)
#
# kubectl-ate is replaced by a stub that records the lifecycle calls hubctl
# makes and emulates substrate's: "suspend actor" pauses the actor container
# (its processes freeze, as in a memory snapshot), and the router stand-in
# unpauses it when a connection arrives, as atenet-router resumes actors.
#
# The second half attaches a real herdr TUI (in tmux) and checks the always-on
# behaviour: the machine stays enabled and shows online while its actor is
# suspended, and input wakes it. Last, a headless Chromium uses the hub's web
# terminal (ttyd) as a second client.
#
# Needs: docker, herdr, websocat, ttyd, ssh, openssl, tmux, python3 with
# `websockets`, node with `playwright` (and its Chromium), and
# atenet-router.ate-system.svc resolving to 127.0.0.1 (add it to /etc/hosts).
# Usage: test/hub-path-test.sh [ACTOR_IMAGE]
# shellcheck disable=SC2015 # "check && ok || bad" is safe: ok and bad always succeed
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-herdr-actor:dev}"
ROUTER_PORT="${ROUTER_PORT:-8443}"
ACTOR_PORT="${ACTOR_PORT:-8102}"
ROUTER_HOST=atenet-router.ate-system.svc
HUB_ID=spiffe://cluster.local/ns/herdr-hub/sa/herdr-hub
NAME="herdr-hub-test-$$"
WORK="$(mktemp -d)"
export ATESPACE=herdr-agents
pass=0 fail=0 hub_pid="" router_pid=""

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

tui() { tmux -L "${NAME}" "$@"; }

cleanup() {
  tui kill-server 2>/dev/null || true
  docker unpause "${NAME}" >/dev/null 2>&1 || true
  [[ -n "${hub_pid}" ]] && kill -- -"${hub_pid}" 2>/dev/null || true
  [[ -n "${router_pid}" ]] && kill "${router_pid}" 2>/dev/null || true
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  pkill -f -- "ate-target-actor: ${ATESPACE}/" 2>/dev/null || true
  if [[ "${KEEP:-0}" == 1 ]]; then echo "kept ${WORK}"; else rm -rf "${WORK}"; fi
}
trap cleanup EXIT

for c in docker herdr websocat ttyd ssh openssl python3 setsid tmux node; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done
python3 -c 'import websockets' 2>/dev/null || { echo "pip install websockets" >&2; exit 1; }
node -e "require('playwright')" 2>/dev/null || { echo "npm install playwright, then npx playwright install chromium" >&2; exit 1; }
getent hosts "${ROUTER_HOST}" | grep -q '127.0.0.1' \
  || { echo "add '127.0.0.1 ${ROUTER_HOST}' to /etc/hosts" >&2; exit 1; }

# --- PKI: servicedns CA (router serving cert), podidentity CA (client certs)
pki="${WORK}/pki"; mkdir -p "${pki}"
mkca() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=$1" -keyout "${pki}/$1.key" -out "${pki}/$1.crt" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}
mkleaf() { # name ca san
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$1" \
    -keyout "${pki}/$1.key" -out "${pki}/$1.csr" 2>/dev/null
  # Full extension set, as real issuers produce (strict verifiers need AKI).
  printf '%s\n' "subjectAltName=$3" "basicConstraints=CA:FALSE" \
    "keyUsage=critical,digitalSignature" "extendedKeyUsage=serverAuth,clientAuth" \
    "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" >"${pki}/$1.ext"
  openssl x509 -req -in "${pki}/$1.csr" -CA "${pki}/$2.crt" -CAkey "${pki}/$2.key" \
    -CAcreateserial -days 1 -extfile "${pki}/$1.ext" -out "${pki}/$1.crt" 2>/dev/null
  # Like the kubelet's credential bundle: private key, then the chain.
  cat "${pki}/$1.key" "${pki}/$1.crt" >"${pki}/$1.bundle.pem"
}
mkca servicedns; mkca podidentity
mkleaf router servicedns "DNS:${ROUTER_HOST}"
mkleaf hub podidentity "URI:${HUB_ID}"
mkleaf rogue podidentity "URI:spiffe://cluster.local/ns/elsewhere/sa/intruder"

# --- kubectl-ate stub
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/kubectl-ate" <<'EOF'
#!/bin/sh
echo "kubectl-ate $*" >>"${STUB_LOG}"
case "$*" in
  *"get actors"*)
    state=ACTOR_STATE_RUNNING
    [ "$(docker inspect -f '{{.State.Paused}}' "${ACTOR_CONTAINER}")" = true ] && state=ACTOR_STATE_SUSPENDED
    printf '{"actors":[{"metadata":{"name":"luna"},"status":{"state":"%s"}}]}\n' "${state}" ;;
  *"suspend actor"*) docker pause "${ACTOR_CONTAINER}" >/dev/null ;;
  *"resume actor"*) docker unpause "${ACTOR_CONTAINER}" >/dev/null 2>&1 || true ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/kubectl-ate"
export STUB_LOG="${WORK}/kubectl-ate.log" ACTOR_CONTAINER="${NAME}"; : >"${STUB_LOG}"
echo token >"${WORK}/token"

export PATH="${WORK}/bin:${KIT_DIR}/hub:${PATH}"
# Keep using your Docker context (Docker Desktop, Colima, ...): the CLI finds
# it under $HOME/.docker, and HOME is about to point at a throwaway directory.
export DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker}"
export HOME="${WORK}/hub-home"; mkdir -p "${HOME}"
export ATE_IDENTITY_BUNDLE="${pki}/hub.bundle.pem" ATE_ROUTER_CA="${pki}/servicedns.crt" \
       ATE_API_TOKEN="${WORK}/token" ATE_ROUTER_URL="wss://${ROUTER_HOST}:${ROUTER_PORT}/" \
       HUB_SHARE="${KIT_DIR}/hub" IDLE_SECONDS=15 POLL_SECONDS=3 \
       HERDR_KEEPER_RUN="${WORK}/keepers" HUB_WEB_PORT="${WEB_PORT:-7699}"

step "1. hub starts and generates its SSH key"
setsid bash "${KIT_DIR}/hub/entrypoint.sh" >"${WORK}/hub.log" 2>&1 &
hub_pid=$!
for _ in $(seq 1 20); do [[ -s "${HOME}/.ssh/id_ed25519.pub" ]] && break; sleep 0.5; done
if [[ -s "${HOME}/.ssh/id_ed25519.pub" ]]; then ok "hub key $(cut -c1-30 "${HOME}/.ssh/id_ed25519.pub")..."; else bad "no hub key"; fi
grep -q "ProxyCommand ate-wss-proxy" "${HOME}/.ssh/config" && ok "hub ssh config rendered" || bad "hub ssh config"
# Listening sockets as hex address:port; the web terminal must be loopback-only.
listeners() { awk 'NR > 1 && $4 == "0A" { print $2 }' /proc/net/tcp; }
web_hex="$(printf '%04X' "${HUB_WEB_PORT}")"
for _ in $(seq 1 20); do listeners | grep -q ":${web_hex}$" && break; sleep 0.5; done
if [[ "$(listeners | grep ":${web_hex}$")" == "0100007F:${web_hex}" ]]; then
  ok "web terminal listens on 127.0.0.1:${HUB_WEB_PORT} only"
else
  bad "web terminal listeners: $(listeners | grep ":${web_hex}$" | tr '\n' ' ')"
fi

step "2. actor trusts the hub key; router stand-in enforces mTLS + routing"
docker run -d --name "${NAME}" -p "127.0.0.1:${ACTOR_PORT}:80" \
  --cap-drop ALL --cap-add AUDIT_WRITE --cap-add KILL --cap-add NET_BIND_SERVICE \
  --cap-add SETUID --cap-add SETGID --cap-add SYS_CHROOT --cap-add CHOWN \
  -e AUTHORIZED_KEYS="$(cat "${HOME}/.ssh/id_ed25519.pub")" "${IMAGE}" >/dev/null
python3 "${KIT_DIR}/test/fake_router.py" --listen "127.0.0.1:${ROUTER_PORT}" \
  --cert "${pki}/router.crt" --key "${pki}/router.key" --client-ca "${pki}/podidentity.crt" \
  --allow "${HUB_ID}" --actor "${ATESPACE}/luna=ws://127.0.0.1:${ACTOR_PORT}/" \
  --container "${ATESPACE}/luna=${NAME}" \
  >"${WORK}/router.log" 2>&1 &
router_pid=$!
for _ in $(seq 1 30); do
  docker logs "${NAME}" 2>&1 | grep -q "Server listening" && grep -q listening "${WORK}/router.log" && break
  sleep 1
done
grep -q listening "${WORK}/router.log" && ok "router stand-in up" || bad "router stand-in: $(cat "${WORK}/router.log")"

step "3. hubctl add: ssh -> ate-wss-proxy (mTLS) -> router -> actor -> herdr machine"
if out="$(hubctl add luna 2>&1)"; then ok "hubctl add luna"; else bad "hubctl add luna: ${out}"; fi
grep -q "ROUTE ${HUB_ID} -> ${ATESPACE}/luna" "${WORK}/router.log" \
  && ok "router saw the hub's SPIFFE identity and target" || bad "no ROUTE line in router log"

step "4. the router refuses what it should"
if ATE_IDENTITY_BUNDLE="${pki}/rogue.bundle.pem" ssh -F "${HOME}/.ssh/config" -o BatchMode=yes -o ConnectTimeout=10 ate-luna true >/dev/null 2>&1; then
  bad "a non-allowlisted identity got through"
else
  grep -q "DENY identity spiffe://cluster.local/ns/elsewhere" "${WORK}/router.log" \
    && ok "non-allowlisted SPIFFE identity refused" || bad "rogue refused, but not by the identity check"
fi
if ssh -F "${HOME}/.ssh/config" -o BatchMode=yes -o ConnectTimeout=10 ate-nonexistent true >/dev/null 2>&1; then
  bad "unknown actor reachable"
else
  grep -q "DENY target 'herdr-agents/nonexistent'" "${WORK}/router.log" \
    && ok "unknown ate-target-actor refused" || bad "unknown actor refused, but not by routing"
fi

step "5. agents on the actor are visible and drivable from the hub"
pane="$(herdr --machine luna workspace create --cwd /work --label demo 2>/dev/null | python3 -c '
import json, sys
print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])' 2>/dev/null || true)"
# shellcheck disable=SC2016 # expanded inside the actor's pane
herdr --machine luna pane run "${pane}" \
  'sh -c '\''herdr pane report-agent "$HERDR_PANE_ID" --source custom:test --agent testbot --state working --seq 1 >/dev/null; exec sleep 100000'\''' >/dev/null 2>&1 || true
status=missing
for _ in 1 2 3 4 5; do
  sleep 2
  status="$(herdr --machine luna agent list 2>/dev/null | python3 -c '
import json, sys
a = [a for a in json.load(sys.stdin)["result"]["agents"] if a.get("agent") == "testbot"]
print(a[0]["agent_status"] if a else "missing")' 2>/dev/null || echo error)"
  [[ "${status}" == working ]] && break
done
[[ "${status}" == working ]] && ok "agent testbot working, seen from the hub" || bad "agent status: ${status}"

[[ "${EXPLORE:-0}" == 1 ]] && { echo "exploring: ${WORK}"; sleep infinity; }

luna_row() { tui capture-pane -p -t tui | grep -m1 '▾ luna' | sed 's/[[:space:]]*$//'; }
paused() { docker inspect -f '{{.State.Paused}}' "${NAME}"; }
keeper_log() { cat "${HERDR_KEEPER_RUN}"/luna/*[0-9].log 2>/dev/null || true; }
key() { tui send-keys -t tui "$@"; sleep 0.5; }

step "6. a herdr TUI attaches; luna is online through a keeper"
tui new-session -d -s tui -x 160 -y 45 herdr
for _ in $(seq 1 40); do [[ "$(luna_row)" == *●* ]] && break; sleep 1; done
[[ "$(luna_row)" == *●* ]] && ok "luna shows online" || bad "luna row: '$(luna_row)'"
compgen -G "${HERDR_KEEPER_RUN}/luna/*.sock" >/dev/null && ok "a keeper carries the TUI's connection" || bad "no keeper socket"
# First-run notice, then open luna's shell workspace (Local, then luna's ~).
key Enter; key Escape; key C-b; key w; key Down; key Enter; sleep 1
tui capture-pane -p -t tui | grep -q 'new · luna' && ok "luna's shell workspace is active" || bad "could not open luna's workspace"

step "7. idle: the actor is suspended while the TUI stays attached"
# The test's own CLI call must not count as user activity.
HERDR_KEEPER_BYPASS=1 herdr --machine luna pane report-agent "${pane}" --source custom:test \
  --agent testbot --state idle --seq 2 >/dev/null 2>&1 || true
start=$SECONDS
until [[ "$(paused)" == true ]] || (( SECONDS - start > 90 )); do sleep 2; done
if [[ "$(paused)" == true ]]; then
  ok "suspended after $((SECONDS - start))s, TUI attached (IDLE_SECONDS=${IDLE_SECONDS})"
else
  bad "never suspended; hub log: $(tail -n 3 "${WORK}/hub.log")"
fi
keeper_log | grep -q '\[parked\] parked' && ok "keeper parked before the suspend" || bad "keeper never parked"
enabled="$(herdr machine list --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["enabled"])')"
[[ "${enabled}" == True ]] && ok "machine stays enabled" || bad "machine was disabled"

step "8. suspended: the TUI keeps showing luna online"
wrong=0 woke=0
for _ in $(seq 1 15); do
  row="$(luna_row)"
  [[ "${row}" == *●* && "${row}" != *connecting* ]] || wrong=$((wrong + 1))
  [[ "$(paused)" == true ]] || woke=1
  sleep 3
done
(( wrong == 0 )) && ok "45s of health checks answered locally; luna never left online" || bad "${wrong} samples not online"
(( woke == 0 )) && ! grep -q RESUME "${WORK}/router.log" && ok "nothing reached the router; the actor stayed suspended" \
  || bad "the actor was woken while idle"
tui resize-window -t tui -x 150 -y 44; sleep 4
[[ "$(paused)" == true ]] && ok "a window resize is held, it doesn't wake the actor" || bad "a resize woke the actor"

step "9. typing wakes it, and the same session carries on"
start=$SECONDS
# shellcheck disable=SC2016 # expanded by the shell on luna, proving the command ran there
tui send-keys -t tui 'echo always-on-$((6*7))' Enter
until tui capture-pane -p -t tui | grep -q 'always-on-42' || (( SECONDS - start > 60 )); do sleep 0.5; done
tui capture-pane -p -t tui | grep -q 'always-on-42' \
  && ok "command ran on luna, output on screen after $((SECONDS - start))s" || bad "no output from luna"
grep -q "RESUME ${ATESPACE}/luna" "${WORK}/router.log" && ok "the router resumed the actor on demand" || bad "no RESUME"
keeper_log | grep -q 'connected (resumed' && ok "keeper rejoined its session" || bad "keeper did not resume its session"
started="$(docker logs "${NAME}" 2>&1 | grep -c 'bridge started' || true)"
[[ "${started}" == 1 ]] && ok "herdr's server-side session never restarted" || bad "bridge started ${started} times"
[[ "$(luna_row)" == *●* ]] && ok "luna online throughout" || bad "luna row: '$(luna_row)'"
hubctl status 2>/dev/null | grep -q 'keeper luna (pid [0-9]*): awake' \
  && ok "hubctl status shows the keeper awake" || bad "hubctl status: $(hubctl status 2>&1 | tail -n 2)"

step "10. a browser is a second client, through the hub's web terminal"
web_run() { # name, then the steps as JSON
  printf '%s' "$2" >"${WORK}/$1.json"
  WEB_SCREENSHOT="${WORK}/$1.png" node "${KIT_DIR}/test/web-client.js" \
    "http://127.0.0.1:${HUB_WEB_PORT}/" "${WORK}/$1.json" >"${WORK}/$1.log" 2>&1
}
# shellcheck disable=SC2016 # expanded by the shell on luna
# Wait for luna's pane itself (step 9's output), not just the sidebar: until
# the new client's connection to luna is up, keys have no pane to go to.
if web_run web-type '[{"wait": "always-on-42", "timeout": 60},
    {"type": "echo browser-$((6*7))"}, {"keys": ["Enter"]}, {"wait": "browser-42", "timeout": 30}]'; then
  ok "typed in the browser; the command ran on luna"
else
  bad "browser: $(tail -n 30 "${WORK}/web-type.log")"
fi
tui capture-pane -p -t tui | grep -q 'browser-42' \
  && ok "the tmux client sees the same pane: one server, two clients" || bad "tmux client did not see the browser's command"
sleep 2
ttyd_pid="$(pgrep -x ttyd | head -n 1)"
[[ -n "${ttyd_pid}" && -z "$(pgrep -P "${ttyd_pid}" || true)" ]] \
  && ok "closing the tab ended its herdr client; the hub keeps running" || bad "herdr client left behind under ttyd"

step "11. the next morning: open the page while luna is suspended"
start=$SECONDS
until [[ "$(paused)" == true ]] || (( SECONDS - start > 90 )); do sleep 2; done
[[ "$(paused)" == true ]] && ok "luna suspended again after $((SECONDS - start))s" || bad "luna never suspended"
# shellcheck disable=SC2016 # expanded by the shell on luna
if web_run web-wake '[{"wait": "browser-42", "timeout": 60},
    {"type": "echo morning-$((6*7))"}, {"keys": ["Enter"]}, {"wait": "morning-42", "timeout": 60}]'; then
  ok "a new tab on a suspended luna works: luna woke and ran the command"
else
  bad "browser: $(tail -n 30 "${WORK}/web-wake.log")"
fi
[[ "$(grep -c "RESUME ${ATESPACE}/luna" "${WORK}/router.log")" -ge 2 ]] \
  && ok "the router resumed luna for the browser" || bad "no second RESUME"

echo; echo "lifecycle calls made by the hub (polls omitted):"; grep -v "get actors" "${STUB_LOG}" | sed 's/^/  /' || true
printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
(( fail == 0 ))
