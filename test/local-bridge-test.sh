#!/usr/bin/env bash
# Exercise the actor image and the host side of the bridge without kind:
#
#   herdr (host) -> ssh -> ProxyCommand websocat -> ws://127.0.0.1:PORT
#     -> docker container running the actor entrypoint (substrate's exact
#        capability set) -> websocat :80 -> sshd -> herdr server
#
# The router is replaced by Docker's port publishing, so the ate-target-actor
# header is sent but not interpreted. test/hub-path-test.sh covers the hub's
# mTLS path to the router. Everything runs under a throwaway HOME:
# your real ~/.ssh and herdr machines are not touched.
#
# Usage: test/local-bridge-test.sh [IMAGE]   (default: herdr-actor:dev)
#        NEGATIVE=1 also proves sshd fails without the extra capabilities.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-herdr-actor:dev}"
PORT="${PORT:-8100}"
NAME="herdr-bridge-test-$$"
TMP_HOME="$(mktemp -d)"
ATESPACE=bridge-test
pass=0 fail=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

cleanup() {
  docker rm -f "${NAME}" "${NAME}-nocaps" >/dev/null 2>&1 || true
  pkill -f -- "ate-target-actor: ${ATESPACE}/" 2>/dev/null || true
  rm -rf "${TMP_HOME}"
}
trap cleanup EXIT

for c in docker ssh ssh-keygen websocat herdr python3; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

# Substrate's default set (cmd/atelet/oci.go) plus the template's additions.
CAPS=(--cap-drop ALL --cap-add AUDIT_WRITE --cap-add KILL --cap-add NET_BIND_SERVICE)
EXTRA=(--cap-add SETUID --cap-add SETGID --cap-add SYS_CHROOT --cap-add CHOWN)

# Keep using your Docker context (Docker Desktop, Colima, ...): the CLI finds
# it under $HOME/.docker, and HOME is about to point at a throwaway directory.
export DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker}"
export HOME="${TMP_HOME}"
mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_test"

step "1. start the actor (substrate capability set)"
docker run -d --name "${NAME}" -p "127.0.0.1:${PORT}:80" "${CAPS[@]}" "${EXTRA[@]}" \
  -e AUTHORIZED_KEYS="$(cat "${HOME}/.ssh/id_test.pub")" "${IMAGE}" >/dev/null
for _ in $(seq 1 30); do
  docker logs "${NAME}" 2>&1 | grep -q "Server listening" && break
  sleep 1
done
logs="$(docker logs "${NAME}" 2>&1)"
if grep -q "pty self-test ok" <<<"${logs}"; then ok "pty self-test"; else bad "pty self-test"; fi
if grep -q "Server listening on 127.0.0.1 port 2222" <<<"${logs}"; then
  ok "sshd on loopback"
else
  bad "sshd did not start; container log:"
  tail -n 15 <<<"${logs}" | while IFS= read -r line; do printf '      %s\n' "${line}"; done
fi

step "2. ssh over the WebSocket, using the kit's ssh_config"
ATESPACE="${ATESPACE}" ROUTER_PORT="${PORT}" SSH_KEY="${HOME}/.ssh/id_test" \
  KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts.test" \
  python3 - "${KIT_DIR}/test/ssh_config.tmpl" >"${HOME}/.ssh/config" <<'PY'
import os, re, sys
print(re.sub(r"\$\{([A-Z0-9_]+)\}", lambda m: os.environ[m.group(1)], open(sys.argv[1]).read()))
PY
chmod 600 "${HOME}/.ssh/config"
if out="$(ssh -F "${HOME}/.ssh/config" -o BatchMode=yes ate-luna 'herdr --version; id -u' 2>&1)"; then
  ok "ssh ate-luna: $(tr '\n' ' ' <<<"${out}")"
else
  bad "ssh ate-luna: ${out}"
fi

step "3. herdr saved machine over the bridge"
if out="$(herdr machine add ate-luna --label luna 2>&1)"; then ok "herdr machine add"; else bad "herdr machine add: ${out}"; fi
pane="$(herdr --machine luna workspace create --cwd /work --label demo 2>/dev/null | python3 -c '
import json, sys
print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])' 2>/dev/null || true)"
if [[ -n "${pane}" ]]; then ok "workspace created on the actor (pane ${pane})"; else bad "workspace create via --machine"; fi

step "4. agent state flows back to the host"
# A stand-in agent that reports its own state from inside its pane, the way
# herdr's integrations do (HERDR_PANE_ID is set for every pane process).
# shellcheck disable=SC2016 # expanded inside the actor's pane, not here
herdr --machine luna pane run "${pane}" \
  'sh -c '\''herdr pane report-agent "$HERDR_PANE_ID" --source custom:test --agent testbot --state working --seq 1 >/dev/null; exec sleep 100000'\''' >/dev/null
status=missing
for _ in 1 2 3 4 5; do
  sleep 2
  status="$(herdr --machine luna agent list | python3 -c '
import json, sys
a = [a for a in json.load(sys.stdin)["result"]["agents"] if a.get("agent") == "testbot"]
print(a[0]["agent_status"] if a else "missing")')"
  [[ "${status}" == working ]] && break
done
if [[ "${status}" == working ]]; then ok "agent testbot reported working"; else bad "agent status: ${status}"; fi

step "5. an operator can still take a machine offline: disabled machines can't be reached"
id="$(herdr machine list --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
herdr machine disable "${id}" >/dev/null
pkill -f -- "ate-target-actor: ${ATESPACE}/luna\$" 2>/dev/null || true
if herdr --machine luna agent list >/dev/null 2>&1; then bad "--machine still routes to a disabled machine"; else ok "--machine refuses the disabled machine"; fi
herdr machine enable "${id}" >/dev/null
if herdr --machine luna agent list >/dev/null 2>&1; then ok "re-enabled machine reachable, state intact"; else bad "re-enable"; fi

if [[ "${NEGATIVE:-0}" == 1 ]]; then
  step "6. negative control: substrate's default capabilities only"
  docker run -d --name "${NAME}-nocaps" "${CAPS[@]}" \
    -e AUTHORIZED_KEYS="$(cat "${HOME}/.ssh/id_test.pub")" "${IMAGE}" >/dev/null
  sleep 4
  docker exec "${NAME}-nocaps" sh -c 'timeout 5 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -p 2222 root@127.0.0.1 true' >/dev/null 2>&1 || true
  if docker logs "${NAME}-nocaps" 2>&1 | grep -q 'chroot.*Operation not permitted'; then
    ok "without SYS_CHROOT sshd fails as expected (chroot: Operation not permitted)"
  else
    bad "expected a chroot failure without the extra capabilities"
  fi
fi

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
(( fail == 0 ))
