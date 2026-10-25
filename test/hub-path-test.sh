#!/usr/bin/env bash
# Exercise the hub without a cluster:
#
#   hub/entrypoint.sh + hubctl + ate-wss-proxy (run natively, throwaway HOME)
#     -> wss:// with a SPIFFE client cert -> test/fake_router.py (enforces the
#        allowlist and ate-target-actor, like atenet-router's mTLS listener)
#     -> actor container (actor image, substrate's capability set)
#
# kubectl-ate is replaced by a stub that records the lifecycle calls hubctl
# makes, so the idle bridge's suspend and resume can be checked.
#
# Needs: docker, herdr, websocat, ssh, openssl, python3 with `websockets`,
# and atenet-router.ate-system.svc resolving to 127.0.0.1 (add it to
# /etc/hosts). Usage: test/hub-path-test.sh [ACTOR_IMAGE]
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

cleanup() {
  [[ -n "${hub_pid}" ]] && kill -- -"${hub_pid}" 2>/dev/null || true
  [[ -n "${router_pid}" ]] && kill "${router_pid}" 2>/dev/null || true
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  pkill -f -- "ate-target-actor: ${ATESPACE}/" 2>/dev/null || true
  if [[ "${KEEP:-0}" == 1 ]]; then echo "kept ${WORK}"; else rm -rf "${WORK}"; fi
}
trap cleanup EXIT

for c in docker herdr websocat ssh openssl python3 setsid; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done
python3 -c 'import websockets' 2>/dev/null || { echo "pip install websockets" >&2; exit 1; }
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
case "$*" in *"get actors"*) echo '{"actors":[]}' ;; esac
exit 0
EOF
chmod +x "${WORK}/bin/kubectl-ate"
export STUB_LOG="${WORK}/kubectl-ate.log"; : >"${STUB_LOG}"
echo token >"${WORK}/token"

export PATH="${WORK}/bin:${KIT_DIR}/hub:${PATH}"
# Keep using your Docker context (Docker Desktop, Colima, ...): the CLI finds
# it under $HOME/.docker, and HOME is about to point at a throwaway directory.
export DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker}"
export HOME="${WORK}/hub-home"; mkdir -p "${HOME}"
export ATE_IDENTITY_BUNDLE="${pki}/hub.bundle.pem" ATE_ROUTER_CA="${pki}/servicedns.crt" \
       ATE_API_TOKEN="${WORK}/token" ATE_ROUTER_URL="wss://${ROUTER_HOST}:${ROUTER_PORT}/" \
       HUB_SHARE="${KIT_DIR}/hub" IDLE_SECONDS=15 POLL_SECONDS=3

step "1. hub starts and generates its SSH key"
setsid bash "${KIT_DIR}/hub/entrypoint.sh" >"${WORK}/hub.log" 2>&1 &
hub_pid=$!
for _ in $(seq 1 20); do [[ -s "${HOME}/.ssh/id_ed25519.pub" ]] && break; sleep 0.5; done
if [[ -s "${HOME}/.ssh/id_ed25519.pub" ]]; then ok "hub key $(cut -c1-30 "${HOME}/.ssh/id_ed25519.pub")..."; else bad "no hub key"; fi
grep -q "ProxyCommand ate-wss-proxy" "${HOME}/.ssh/config" && ok "hub ssh config rendered" || bad "hub ssh config"

step "2. actor trusts the hub key; router stand-in enforces mTLS + routing"
docker run -d --name "${NAME}" -p "127.0.0.1:${ACTOR_PORT}:80" \
  --cap-drop ALL --cap-add AUDIT_WRITE --cap-add KILL --cap-add NET_BIND_SERVICE \
  --cap-add SETUID --cap-add SETGID --cap-add SYS_CHROOT --cap-add CHOWN \
  -e AUTHORIZED_KEYS="$(cat "${HOME}/.ssh/id_ed25519.pub")" "${IMAGE}" >/dev/null
python3 "${KIT_DIR}/test/fake_router.py" --listen "127.0.0.1:${ROUTER_PORT}" \
  --cert "${pki}/router.crt" --key "${pki}/router.key" --client-ca "${pki}/podidentity.crt" \
  --allow "${HUB_ID}" --actor "${ATESPACE}/luna=ws://127.0.0.1:${ACTOR_PORT}/" \
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

step "6. idle bridge suspends the actor once its agent goes idle"
herdr --machine luna pane report-agent "${pane}" --source custom:test --agent testbot --state idle --seq 2 >/dev/null 2>&1 || true
start=$SECONDS
until grep -q "suspend actor luna -a ${ATESPACE}" "${STUB_LOG}" || (( SECONDS - start > 60 )); do sleep 2; done
if grep -q "suspend actor luna -a ${ATESPACE}" "${STUB_LOG}"; then
  ok "suspended after $((SECONDS - start))s (IDLE_SECONDS=${IDLE_SECONDS}, POLL_SECONDS=${POLL_SECONDS})"
else
  bad "idle bridge never suspended; hub log: $(tail -n 5 "${WORK}/hub.log")"
fi
enabled="$(herdr machine list --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["enabled"])')"
[[ "${enabled}" == False ]] && ok "machine disabled before the suspend" || bad "machine still enabled"
if herdr --machine luna agent list >/dev/null 2>&1; then bad "--machine still reaches the suspended actor"; else ok "--machine refuses it while suspended"; fi

step "7. hubctl resume"
hubctl resume luna >/dev/null 2>&1 || true
grep -q "resume actor luna -a ${ATESPACE}" "${STUB_LOG}" && ok "resume call made" || bad "no resume call"
status="$(herdr --machine luna agent list 2>/dev/null | python3 -c '
import json, sys
a = [a for a in json.load(sys.stdin)["result"]["agents"] if a.get("agent") == "testbot"]
print(a[0]["agent_status"] if a else "missing")' 2>/dev/null || echo error)"
case "${status}" in idle|done) ok "machine re-enabled, agent state intact (${status})" ;; *) bad "after resume: ${status}" ;; esac

echo; echo "lifecycle calls made by the hub:"; sed 's/^/  /' "${STUB_LOG}"
printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
(( fail == 0 ))
