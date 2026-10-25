#!/usr/bin/env bash
# Actor entrypoint: runs three supervised services and never exits.
#
#   websocat :80  ->  sshd 127.0.0.1:2222  ->  herdr server (owns the agent PTYs)
#
# Everything here is captured by substrate's MEMORY snapshots, so after a
# suspend/resume the herdr server and any running agents come back as they were.
#
# Environment (set in the ActorTemplate):
#   AUTHORIZED_KEYS   required; SSH public key(s), one per line
#   ACTOR_LISTEN      optional; websocat listen address (default 0.0.0.0:80)
#   SSHD_PORT         optional; must match sshd_config (default 2222)
set -euo pipefail

log() { printf '[herdr-actor] %s\n' "$*" >&2; }

ACTOR_LISTEN="${ACTOR_LISTEN:-0.0.0.0:80}"
SSHD_PORT="${SSHD_PORT:-2222}"
SSH_STATE=/etc/ssh/actor

if [[ -z "${AUTHORIZED_KEYS:-}" ]]; then
  log "AUTHORIZED_KEYS is empty; refusing to start an SSH endpoint nobody can use"
  exit 1
fi

# --- SSH host key and authorized keys -------------------------------------
# The host key is generated on first boot, i.e. while substrate builds the
# template's golden snapshot. Every actor cloned from that snapshot therefore
# shares one host key; the host-side ssh config pins it with HostKeyAlias.
mkdir -p "${SSH_STATE}" /run/sshd
chmod 0700 "${SSH_STATE}"
if [[ ! -f "${SSH_STATE}/ssh_host_ed25519_key" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C herdr-actor -f "${SSH_STATE}/ssh_host_ed25519_key"
  log "generated SSH host key $(ssh-keygen -lf "${SSH_STATE}/ssh_host_ed25519_key.pub")"
fi
printf '%s\n' "${AUTHORIZED_KEYS}" >"${SSH_STATE}/authorized_keys"
chmod 0600 "${SSH_STATE}/authorized_keys"

# --- PTY self-test ---------------------------------------------------------
# herdr panes and sshd sessions both need /dev/ptmx + devpts. The gVisor OCI
# spec only mounts a tmpfs on /dev; runsc is expected to provide ptys itself.
# If this fails, use the micro-VM sandbox class (needs /dev/kvm), whose spec
# mounts devpts explicitly.
if python3 -c 'import os; m, s = os.openpty(); os.close(m); os.close(s)' 2>/dev/null; then
  log "pty self-test ok"
else
  log "WARNING: cannot allocate a pseudo-terminal; herdr panes and ssh sessions will fail"
fi

# --- supervised services ---------------------------------------------------
supervise() {
  local name="$1"; shift
  while true; do
    log "starting ${name}"
    "$@" || log "${name} exited with status $?"
    sleep 1
  done
}

/usr/sbin/sshd -t || { log "sshd config test failed"; exit 1; }

supervise sshd /usr/sbin/sshd -D -e &

# Headless herdr server (default session). Panes it spawns inherit this
# environment: ANTHROPIC_API_KEY placeholder, NODE_EXTRA_CA_CERTS, etc.
# It must lead its own session: saved-machine clients refuse a server that
# is not a detached daemon (getsid(0) == getpid()). `setsid --wait` gives it
# a new session while keeping it in the foreground for the supervisor.
supervise herdr bash -c 'cd /work && exec setsid --wait herdr server' &

# WebSocket -> SSH. Fixed target: this is not a general-purpose proxy.
# Pings keep idle tunnels alive through the router and kubectl port-forward,
# and the timeout reaps tunnels whose peer vanished (e.g. across a suspend).
supervise websocat websocat --binary --exit-on-eof \
  --ping-interval 20 --ping-timeout 60 \
  "ws-l:${ACTOR_LISTEN}" "tcp:127.0.0.1:${SSHD_PORT}" &

log "ready: ws://${ACTOR_LISTEN} -> ssh 127.0.0.1:${SSHD_PORT}"
wait
