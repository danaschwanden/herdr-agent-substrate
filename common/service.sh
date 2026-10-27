# Shared by the actor's and the hub's entrypoints (sourced, not run).
# Installed in both images at /usr/local/lib/herdr-substrate/service.sh.
#
#   LOG_TAG         prefix for log lines, e.g. herdr-actor
#   RESTART_DELAY   seconds between restarts of a supervised service (default 1)
# shellcheck shell=bash

log() { printf '[%s] %s\n' "${LOG_TAG:-service}" "$*" >&2; }

# supervise NAME CMD...: run CMD forever, restarting it when it exits.
supervise() {
  local name="$1"; shift
  while true; do
    log "starting ${name}"
    "$@" || log "${name} exited with status $?"
    sleep "${RESTART_DELAY:-1}"
  done
}
