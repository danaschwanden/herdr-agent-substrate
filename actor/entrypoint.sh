#!/usr/bin/env bash
# Actor entrypoint: runs four supervised services and never exits.
#
#   websocat :80  ->  sshd 127.0.0.1:2222  ->  herdr server (owns the agent PTYs)
#   herdr-anchor: keeps the hub's client sessions to that server across suspends
#
# Everything here is captured by substrate's MEMORY snapshots, so after a
# suspend/resume the herdr server and any running agents come back as they were.
#
# Environment (set in the ActorTemplate):
#   AUTHORIZED_KEYS   required; SSH public key(s), one per line
set -euo pipefail

# log and supervise, shared with the hub's entrypoint (common/service.sh).
# shellcheck disable=SC2034 # read by service.sh
LOG_TAG=herdr-actor RESTART_DELAY=1
for lib in /usr/local/lib/herdr-substrate/service.sh "$(dirname "$(readlink -f "$0")")/../common/service.sh"; do
  # shellcheck source=/dev/null
  [[ -f "${lib}" ]] && { . "${lib}"; break; }
done
declare -F supervise >/dev/null || { echo "[herdr-actor] service.sh not found" >&2; exit 1; }

# Fixed: port 80 is the one port substrate's router forwards, and sshd_config
# pins sshd to 127.0.0.1:2222.
ACTOR_LISTEN=0.0.0.0:80
SSHD_ADDR=127.0.0.1:2222
SSH_STATE=/etc/ssh/actor

if [[ -z "${AUTHORIZED_KEYS:-}" ]]; then
  log "AUTHORIZED_KEYS is empty; refusing to start an SSH endpoint nobody can use"
  exit 1
fi

# --- temp directories --------------------------------------------------------
# The sandbox's rootfs can surface /tmp as 0777 without the sticky bit. Claude
# Code then refuses to create its cross-session messaging socket there.
for d in /tmp /var/tmp; do
  [[ -d "${d}" ]] || continue
  chmod 1777 "${d}" 2>/dev/null || log "WARNING: could not set mode 1777 on ${d}"
done

# --- the egress gateway's CA, system-wide -------------------------------------
# The gateway terminates TLS to inject credentials. Node tools (Claude Code)
# trust its CA through NODE_EXTRA_CA_CERTS; native ones (Codex, agy, git, curl)
# read the system store, so add it there too.
mitm_ca=/run/ate/trust-bundle.pem
if [[ -s "${mitm_ca}" ]]; then
  mkdir -p /usr/local/share/ca-certificates
  cp "${mitm_ca}" /usr/local/share/ca-certificates/ate-egress-mitm.crt
  update-ca-certificates >/dev/null 2>&1 || log "WARNING: could not add the egress CA to the system store"
else
  log "WARNING: ${mitm_ca} is missing (no systemInfo trust bundle in the ActorTemplate?);" \
      "Codex, agy and other native tools will fail TLS through the egress gateway"
fi

# --- agent CLIs ----------------------------------------------------------------
# Codex and agy need their placeholder credentials in their own config files.
agent-setup || log "WARNING: agent-setup failed; Codex or agy may ask you to sign in"

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

/usr/sbin/sshd -t || { log "sshd config test failed"; exit 1; }

supervise sshd /usr/sbin/sshd -D -e &

# Headless herdr server (default session). Panes it spawns inherit this
# environment: ANTHROPIC_API_KEY placeholder, NODE_EXTRA_CA_CERTS, etc.
# It must lead its own session: saved-machine clients refuse a server that
# is not a detached daemon (getsid(0) == getpid()). `setsid --wait` gives it
# a new session while keeping it in the foreground for the supervisor.
supervise herdr bash -c 'cd /work && exec setsid --wait herdr server' &

# Holds the hub's herdr client sessions across suspends: the bridge to the
# herdr server lives here, in the memory snapshot, while the hub is parked.
supervise herdr-anchor bash -c 'cd /work && exec herdr-anchor serve' &

# WebSocket -> SSH. Fixed target: this is not a general-purpose proxy.
# Pings keep idle tunnels alive through the router and kubectl port-forward,
# and the timeout reaps tunnels whose peer vanished (e.g. across a suspend).
supervise websocat websocat --binary --exit-on-eof \
  --ping-interval 20 --ping-timeout 60 \
  "ws-l:${ACTOR_LISTEN}" "tcp:${SSHD_ADDR}" &

log "ready: ws://${ACTOR_LISTEN} -> ssh ${SSHD_ADDR}"
wait
