#!/usr/bin/env bash
# herdr <-> agent-substrate on kind, hub topology:
#
#   agents   -> one substrate actor each (gVisor), herdr server inside
#   hub      -> an ordinary pod: the herdr client for all actors + the
#               lifecycle controller (idle bridge, suspend/resume)
#   you      -> kubectl exec into the hub and run herdr there (attach), or
#               the same through a browser and port-forward (web)
#
# Run `host/herdr-substrate.sh help` for the steps. Configuration comes from
# the environment, or from a .env file next to this kit's README.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "${KIT_DIR}/.env" ]] && set -a && . "${KIT_DIR}/.env" && set +a

SUBSTRATE_DIR="${SUBSTRATE_DIR:-${KIT_DIR}/../substrate}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${KIND_CLUSTER_NAME}}"
ATESPACE="${ATESPACE:-herdr-agents}"
K8S_NAMESPACE="${K8S_NAMESPACE:-herdr-agents}"
SECRETS_NAMESPACE="${SECRETS_NAMESPACE:-herdr-agents-secrets}"
HUB_NAMESPACE="${HUB_NAMESPACE:-herdr-hub}"
WORKER_REPLICAS="${WORKER_REPLICAS:-2}"
TEMPLATE_NAME="herdr-agent"
REGISTRY="${REGISTRY:-localhost:5001}"
HERDR_VERSION="${HERDR_VERSION:-0.9.5}"
IDLE_SECONDS="${IDLE_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-30}"
# Web terminal in the hub. The default listens on the pod's loopback, reached
# only through `web` (kubectl port-forward). The production guides set
# HUB_WEB_ADDR=0.0.0.0 behind IAP or oauth2-proxy, and HUB_WEB_AUTH_HEADER to
# the header that proxy sets for signed-in users.
HUB_WEB_ADDR="${HUB_WEB_ADDR:-127.0.0.1}"
HUB_WEB_AUTH_HEADER="${HUB_WEB_AUTH_HEADER:-}"
# Local port `web` listens on.
WEB_PORT="${WEB_PORT:-7681}"
# How substrate's egress gateway (atenet-egress) resolves upstream hosts.
# Substrate ships ALL, which tries IPv6 first; where pods have no IPv6 route
# (kind on Docker Desktop, most IPv4-only clusters) that attempt fails at once
# with "network unreachable" and the request ends in a 503 instead of falling
# back to IPv4. V4_PREFERRED uses IPv4 when a host has an A record and still
# reaches IPv6-only hosts. Empty leaves substrate's setting alone.
EGRESS_DNS_FAMILY="${EGRESS_DNS_FAMILY-V4_PREFERRED}"
# Image platform; empty builds for this machine's architecture (right for kind).
# Set it to the cluster nodes' platform elsewhere, e.g. linux/amd64.
PLATFORM="${PLATFORM:-}"
# Claude Code release baked into the actor image; empty means the Dockerfile's
# default (latest). Pin it for production.
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-}"
# Codex release baked into the actor image; empty means latest. (agy has no
# version pin: its installer takes Google's current release.)
CODEX_VERSION="${CODEX_VERSION:-}"
# Digest-pinned ateworker-gvisor image. Empty: borrow it from the counter demo,
# as `cluster` sets up on kind.
WORKER_IMAGE="${WORKER_IMAGE:-}"
# Node selector for the workers, as a YAML/JSON flow map. {} schedules anywhere.
WORKER_NODE_SELECTOR="${WORKER_NODE_SELECTOR:-{\}}"
# Egress credential provider the cluster was installed with. With k8s.io,
# `deploy` stores ANTHROPIC_API_KEY in a Secret and grants the atespace access;
# with any other provider the key is stored outside this kit, and CREDENTIAL_URI
# must name it.
CREDENTIAL_PROVIDER="${CREDENTIAL_PROVIDER:-k8s.io}"
# Prebuilt images (e.g. from the kit's GitHub workflow) instead of `image` and
# `hub-image`: a tag, resolved to its digest when used, or a digest reference.
# The hub image's kubectl-ate must come from the cluster's substrate release.
ACTOR_IMAGE="${ACTOR_IMAGE:-}"
HUB_IMAGE="${HUB_IMAGE:-}"
# How Claude Code in the actors authenticates. Either way the real credential
# stays outside the sandbox: the actor holds a placeholder, and the egress
# gateway swaps in the real one on the way to api.anthropic.com.
#   api-key      an Anthropic API key (ANTHROPIC_API_KEY), billed per use;
#                injected as the x-api-key header
#   oauth-token  a Claude subscription token from `claude setup-token`
#                (CLAUDE_CODE_OAUTH_TOKEN); injected as Authorization: Bearer
CLAUDE_AUTH="${CLAUDE_AUTH:-api-key}"
case "${CLAUDE_AUTH}" in
  api-key)
    CLAUDE_AUTH_ENV=ANTHROPIC_API_KEY
    CLAUDE_AUTH_PLACEHOLDER=placeholder-replaced-by-egress-gateway
    CREDENTIAL_KEY=api-key ;;
  oauth-token)
    CLAUDE_AUTH_ENV=CLAUDE_CODE_OAUTH_TOKEN
    CLAUDE_AUTH_PLACEHOLDER=sk-ant-oat01-placeholder-replaced-by-egress-gateway
    CREDENTIAL_KEY=oauth-token ;;
  *) printf 'error: CLAUDE_AUTH must be api-key or oauth-token, got %s\n' "${CLAUDE_AUTH}" >&2; exit 1 ;;
esac
CREDENTIAL_URI="${CREDENTIAL_URI:-ate-secret://k8s.io/default/${SECRETS_NAMESPACE}/anthropic/${CREDENTIAL_KEY}}"
# Which agent CLIs get credentials, comma-separated. The actor image always has
# all three; each one listed here gets a placeholder in the template and an
# egress rule that injects its real key:
#   claude  Claude Code  -> api.anthropic.com (CLAUDE_AUTH decides how)
#   codex   Codex        -> api.openai.com, OPENAI_API_KEY as Authorization: Bearer
#   agy     Antigravity  -> generativelanguage.googleapis.com, GEMINI_API_KEY as x-goog-api-key
AGENTS="${AGENTS:-claude}"
OPENAI_CREDENTIAL_URI="${OPENAI_CREDENTIAL_URI:-ate-secret://k8s.io/default/${SECRETS_NAMESPACE}/openai/api-key}"
GEMINI_CREDENTIAL_URI="${GEMINI_CREDENTIAL_URI:-ate-secret://k8s.io/default/${SECRETS_NAMESPACE}/gemini/api-key}"
IFS=',' read -r -a AGENT_LIST <<<"${AGENTS// /}"
for a in "${AGENT_LIST[@]}"; do
  case "${a}" in claude|codex|agy) ;; *) printf 'error: AGENTS may list claude, codex and agy, got %s\n' "${a}" >&2; exit 1 ;; esac
done
(( ${#AGENT_LIST[@]} > 0 )) || { printf 'error: AGENTS is empty\n' >&2; exit 1; }
agent_enabled() { [[ ",${AGENTS// /}," == *",$1,"* ]]; }
STATE_DIR="${KIT_DIR}/.state"
mkdir -p "${STATE_DIR}"

# The hub's identity on the router's mTLS listener. substrate's Envoy router
# refuses every client not in this install-time allowlist.
HUB_SPIFFE_ID="spiffe://cluster.local/ns/${HUB_NAMESPACE}/sa/herdr-hub"

log()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

k()   { kubectl --context "${KUBE_CONTEXT}" "$@"; }
ate() { kubectl ate --context "${KUBE_CONTEXT}" "$@"; }
hub() { k -n "${HUB_NAMESPACE}" exec deploy/herdr-hub -- "$@"; }

# `go install ./cmd/kubectl-ate` (the cluster step) puts it in Go's bin
# directory, which is often not on PATH. `kubectl ate` finds plugins via PATH.
if ! command -v kubectl-ate >/dev/null 2>&1 && command -v go >/dev/null 2>&1; then
  gobin="$(go env GOBIN 2>/dev/null)"
  [[ -n "${gobin}" ]] || gobin="$(go env GOPATH 2>/dev/null)/bin"
  [[ -x "${gobin}/kubectl-ate" ]] && PATH="${gobin}:${PATH}"
  unset gobin
fi

need() {
  local missing="" c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing="${missing} ${c}"; done
  [[ -z "${missing}" ]] || die "missing on PATH:${missing}"
}

# render FILE: substitute ${VARS} from the environment; fail on any unset one.
render() {
  python3 - "$1" <<'PY'
import os, re, sys
path = sys.argv[1]
src = open(path).read()
def sub(m):
    key = m.group(1)
    if key not in os.environ:
        sys.exit(f"render: {path} needs ${{{key}}} in the environment")
    return os.environ[key]
sys.stdout.write(re.sub(r"\$\{([A-Z0-9_]+)\}", sub, src))
PY
}

json_quote() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'; }

# json_get PATH: read JSON on stdin, print a dotted path ("" when absent).
json_get() {
  python3 -c '
import json, sys
v = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    v = v.get(part) if isinstance(v, dict) else None
print("" if v is None else v)' "$1"
}

validate_name() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "actor name '$1' must be a DNS label (lowercase, digits, -)"
}

# local_registry: true when REGISTRY is the kind registry on this machine.
local_registry() {
  case "${REGISTRY}" in localhost:*|localhost|127.0.0.1:*|127.0.0.1) return 0 ;; esac
  return 1
}

# image_platform: PLATFORM, or linux/<this machine's arch>.
image_platform() {
  if [[ -n "${PLATFORM}" ]]; then
    echo "${PLATFORM}"
  else
    echo "linux/$(go env GOARCH)"
  fi
}

# Pushes to the kind registry (localhost:5001) only work from a builder that
# uses the "docker" driver: a "docker-container" builder runs BuildKit in its
# own container, where localhost is not the Docker host, and the push hangs.
# Remote registries work with either driver.
check_builder() {
  local_registry || return 0
  local name driver
  name="$(docker buildx inspect 2>/dev/null | awk '/^Name:/ {print $2; exit}')"
  driver="$(docker buildx inspect 2>/dev/null | awk '/^Driver:/ {print $2; exit}')"
  case "${driver}" in
    docker) ;;
    "") warn "could not determine the buildx builder's driver; pushes to ${REGISTRY} need the 'docker' driver" ;;
    *) die "the active buildx builder '${name}' uses the '${driver}' driver, which cannot push to ${REGISTRY}.
Pick a 'docker'-driver builder (see 'docker buildx ls'), e.g. add to .env:
  BUILDX_BUILDER=desktop-linux    # Docker Desktop; 'default' on Linux" ;;
  esac
}

# registry_digest NAME TAG: manifest digest the kind registry stores for
# NAME:TAG. Uses 127.0.0.1 for localhost, sidestepping IPv6 localhost
# forwarding problems on macOS.
registry_digest() {
  python3 - "${REGISTRY}" "$1" "$2" <<'PY'
import sys, urllib.request
registry, name, tag = sys.argv[1:4]
host, _, port = registry.rpartition(":")
if host in ("localhost", ""):
    host = "127.0.0.1"
req = urllib.request.Request(f"http://{host}:{port}/v2/{name}/manifests/{tag}", method="HEAD")
req.add_header("Accept", ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
]))
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(resp.headers.get("Docker-Content-Digest", ""))
except Exception as exc:
    print(f"registry_digest: {exc}", file=sys.stderr)
PY
}

# remote_digest REF: manifest digest of REF in any registry docker can read.
remote_digest() {
  docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>/dev/null | json_get digest
}

# pinned_image NAME REF BUILD_CMD: NAME's digest-pinned reference. REF (a
# prebuilt image, by tag or digest) wins; otherwise what BUILD_CMD recorded.
pinned_image() {
  local name="$1" ref="$2" build_cmd="$3" repo digest
  if [[ -z "${ref}" ]]; then
    [[ -s "${STATE_DIR}/${name}-image" ]] || die "no ${name} image: run '$0 ${build_cmd}', or set a prebuilt one in .env"
    cat "${STATE_DIR}/${name}-image"
    return
  fi
  if [[ "${ref}" == *@sha256:* ]]; then
    echo "${ref}"
    return
  fi
  # Drop the tag (the last ':' after the last '/'; a registry port stays).
  repo="${ref}"
  [[ "${repo##*/}" == *:* ]] && repo="${repo%:*}"
  digest="$(remote_digest "${ref}" || true)"
  [[ "${digest}" == sha256:* ]] || die "could not resolve ${ref} to a digest (does it exist, and is it public or are you logged in?)"
  log "${name}: ${ref} is ${digest}"
  echo "${repo}@${digest}"
}

# build_push DIR NAME: build DIR for image_platform, push it to REGISTRY, and
# record NAME's digest-pinned reference in .state/NAME-image.
build_push() {
  local dir="$1" name="$2" platform tag meta digest
  local -a args
  check_builder
  local_registry && check_disk
  platform="$(image_platform)"
  tag="${REGISTRY}/${name}:dev"
  meta="${STATE_DIR}/${name}-meta.json"
  # Both images take common/ (protocol and shell helpers they share) as the
  # named build context "common".
  args=(--platform "${platform}" --build-arg "HERDR_VERSION=${HERDR_VERSION}"
        --build-context "common=${KIT_DIR}/common")
  [[ -n "${CLAUDE_CODE_VERSION}" ]] && args+=(--build-arg "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}")
  [[ -n "${CODEX_VERSION}" ]] && args+=(--build-arg "CODEX_VERSION=${CODEX_VERSION}")
  log "building ${tag} for ${platform} and pushing it to ${REGISTRY}"
  docker buildx build "${args[@]}" -t "${tag}" --push --metadata-file "${meta}" "${dir}"
  # BuildKit records the digest when it pushes; when the Docker engine pushes
  # (docker driver with the classic image store) it doesn't, so ask the registry.
  digest="$(json_get containerimage.digest <"${meta}" 2>/dev/null || true)"
  if [[ "${digest}" != sha256:* ]]; then
    if local_registry; then
      digest="$(registry_digest "${name}" dev)"
    else
      digest="$(remote_digest "${tag}" || true)"
    fi
  fi
  [[ "${digest}" == sha256:* ]] || die "could not determine the digest of ${tag} (metadata: ${meta})"
  echo "${REGISTRY}/${name}@${digest}" >"${STATE_DIR}/${name}-image"
  log "${name}: $(cat "${STATE_DIR}/${name}-image")"
}

# check_disk: warn when the kind node's filesystem runs low. Everything the
# cluster writes (postgres, snapshots, metrics, pulled images) lands there,
# and a full disk shows up as unrelated-looking crashes.
check_disk() {
  local node="${KIND_CLUSTER_NAME}-control-plane" avail_kb
  docker inspect "${node}" >/dev/null 2>&1 || return 0
  avail_kb="$(docker exec "${node}" df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "${avail_kb}" =~ ^[0-9]+$ ]] || return 0
  if (( avail_kb < 20 * 1024 * 1024 )); then
    warn "only $(( avail_kb / 1024 / 1024 )) GB free on Docker's disk (kind node); below 20 GB, postgres and the snapshot store start crashing.
Free space with: docker builder prune -a -f   and raise Docker Desktop's disk limit"
  else
    log "Docker disk: $(( avail_kb / 1024 / 1024 )) GB free"
  fi
}

# ---------------------------------------------------------------- steps ----

cmd_check() {
  need docker kubectl go git python3
  [[ -d "${SUBSTRATE_DIR}/hack" ]] || die "SUBSTRATE_DIR=${SUBSTRATE_DIR} is not a substrate checkout (git clone https://github.com/agent-substrate/substrate)"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
  check_builder
  check_disk
  log "prerequisites ok"
}

cmd_cluster() {
  cmd_check
  local ids="${HUB_SPIFFE_ID}"
  [[ -n "${ATE_INGRESS_ALLOWED_SPIFFE_IDS:-}" ]] && ids="${ATE_INGRESS_ALLOWED_SPIFFE_IDS},${ids}"
  log "creating kind cluster '${KIND_CLUSTER_NAME}' with substrate's script"
  ( cd "${SUBSTRATE_DIR}" && KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}" hack/create-kind-cluster.sh )
  log "installing substrate (k8s.io credential provider; router allows ${ids})"
  ( cd "${SUBSTRATE_DIR}" && KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}" ATE_INGRESS_ALLOWED_SPIFFE_IDS="${ids}" \
      hack/install-ate-kind.sh deploy ate-system --credential-provider='{"name":"k8s.io"}' )
  # The counter demo is deployed only so its WorkerPool hands us a worker
  # image that substrate's installer built and version-stamped. (ate-setup
  # registers it as demo-counter; the subcommand drops the demo- prefix.)
  log "deploying demo-counter (source of the ateworker-gvisor image)"
  ( cd "${SUBSTRATE_DIR}" && KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}" ATE_INGRESS_ALLOWED_SPIFFE_IDS="${ids}" \
      hack/install-ate-kind.sh deploy demo counter )
  # Only the pool's spec.workerImage is needed; its workers would just hold
  # memory and disk.
  log "scaling the counter demo's workers to 0 (only its worker image is used)"
  k -n ate-demo-counter patch workerpool counter --type merge -p '{"spec":{"replicas":0}}'
  cmd_egress_dns
  log "installing kubectl-ate"
  ( cd "${SUBSTRATE_DIR}" && go install ./cmd/kubectl-ate )
  command -v kubectl-ate >/dev/null || warn "kubectl-ate is not on PATH; add \$(go env GOPATH)/bin"
  check_disk
}

cmd_image() {
  need docker go
  build_push "${KIT_DIR}/actor" herdr-actor
}

cmd_hub_image() {
  need docker go
  local arch; arch="$(image_platform)"; arch="${arch#linux/}"
  [[ "${arch}" != *,* ]] || die "PLATFORM must name one platform for the hub image (kubectl-ate is built for it), got $(image_platform)"
  log "building kubectl-ate for linux/${arch} from ${SUBSTRATE_DIR}"
  mkdir -p "${KIT_DIR}/hub/bin/linux-${arch}"
  ( cd "${SUBSTRATE_DIR}" && CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" \
      go build -trimpath -o "${KIT_DIR}/hub/bin/linux-${arch}/kubectl-ate" ./cmd/kubectl-ate )
  build_push "${KIT_DIR}/hub" herdr-hub
}

# The kit's egress policy for an actor: only api.anthropic.com, with the
# credential from CREDENTIAL_URI injected by the gateway, in the header that
# CLAUDE_AUTH calls for. Used by `actor` and, through the ConfigMap `hub`
# writes, by `hubctl create`.
render_egress_policy() {
  local parts=() tmpl
  if agent_enabled claude; then
    tmpl="${KIT_DIR}/manifests/egress-policy.yaml.tmpl"
    [[ "${CLAUDE_AUTH}" == oauth-token ]] && tmpl="${KIT_DIR}/manifests/egress-policy-oauth-token.yaml.tmpl"
    parts+=("${tmpl}")
  fi
  agent_enabled codex && parts+=("${KIT_DIR}/manifests/egress-rule-codex.yaml.tmpl")
  agent_enabled agy && parts+=("${KIT_DIR}/manifests/egress-rule-agy.yaml.tmpl")
  # One policy per actor: the first file whole, then only the rules of the rest.
  local first=1 part
  for part in "${parts[@]}"; do
    ATESPACE="${ATESPACE}" CREDENTIAL_URI="${CREDENTIAL_URI}" \
      OPENAI_CREDENTIAL_URI="${OPENAI_CREDENTIAL_URI}" GEMINI_CREDENTIAL_URI="${GEMINI_CREDENTIAL_URI}" \
      render "${part}" | if (( first )); then cat; else sed -n '/^rules:/,$p' | tail -n +2; fi
    first=0
  done >"$1"
}

# The template's placeholder credentials, as YAML env entries (6 spaces deep).
agent_env_yaml() {
  local out=""
  if agent_enabled claude; then
    out+="  - name: ${CLAUDE_AUTH_ENV}"$'\n'"    value: \"${CLAUDE_AUTH_PLACEHOLDER}\""$'\n'
  fi
  if agent_enabled codex; then
    out+="  - name: OPENAI_API_KEY"$'\n'"    value: \"sk-placeholder-replaced-by-egress-gateway\""$'\n'
  fi
  if agent_enabled agy; then
    out+="  - name: GEMINI_API_KEY"$'\n'"    value: \"placeholder-replaced-by-egress-gateway\""$'\n'
  fi
  printf '%s' "${out%$'\n'}"
}

# store_secret NAME KEY VALUE: one agent credential, in the secrets namespace.
store_secret() {
  SECRET_NAME="$1" CREDENTIAL_KEY="$2" CREDENTIAL_JSON="$(printf '%s' "$3" | json_quote)" \
    render "${KIT_DIR}/manifests/agent-secret.yaml.tmpl" | k apply -f -
}

# The real credential for the k8s.io provider, from the environment.
claude_credential() {
  if [[ "${CLAUDE_AUTH}" == oauth-token ]]; then
    printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  else
    printf '%s' "${ANTHROPIC_API_KEY:-}"
  fi
}

cmd_hub() {
  need kubectl python3
  local hub_image
  hub_image="$(pinned_image herdr-hub "${HUB_IMAGE}" hub-image)"
  export HUB_NAMESPACE ATESPACE IDLE_SECONDS POLL_SECONDS HUB_WEB_ADDR HUB_WEB_AUTH_HEADER TEMPLATE_NAME
  export HUB_IMAGE="${hub_image}"
  log "deploying the hub in namespace ${HUB_NAMESPACE}"
  render "${KIT_DIR}/manifests/hub.yaml.tmpl" | k apply -f -
  # The default egress policy for `hubctl create`, the same one `actor` uses.
  render_egress_policy "${STATE_DIR}/egress-policy.yaml"
  k -n "${HUB_NAMESPACE}" create configmap herdr-hub-egress-policy \
    --from-file=egress-policy.yaml="${STATE_DIR}/egress-policy.yaml" --dry-run=client -o yaml | k apply -f -
  k -n "${HUB_NAMESPACE}" rollout status deployment/herdr-hub --timeout=5m
  local _
  for _ in $(seq 1 30); do
    hub hubctl pubkey >"${STATE_DIR}/hub.pub" 2>/dev/null && break
    sleep 2
  done
  [[ -s "${STATE_DIR}/hub.pub" ]] || die "the hub did not produce an SSH key; see: kubectl -n ${HUB_NAMESPACE} logs deploy/herdr-hub"
  log "hub SSH key: $(cut -d' ' -f1-2 "${STATE_DIR}/hub.pub" | cut -c1-60)..."
}

grant_secret_namespace() {
  local cm current
  cm=k8s-credential-provider-namespace-policy
  # The data key itself contains a dot, so read it directly (not via json_get).
  current="$(k -n ate-system get configmap "${cm}" -o json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data", {}).get("namespace-policy.yaml", ""))')"
  if grep -q "atespace: ${ATESPACE}\$" <<<"${current}"; then
    log "credential provider already grants ${ATESPACE}"
    return
  fi
  if ! grep -q '^policies: \[\]' <<<"${current}"; then
    die "the credential provider already has a custom policy; add this entry by hand:
  - atespace: ${ATESPACE}
    allowedNamespaces: [${SECRETS_NAMESPACE}]
then: kubectl -n ate-system rollout restart deployment/k8s-credential-provider"
  fi
  log "granting atespace ${ATESPACE} the Secrets in ${SECRETS_NAMESPACE}"
  python3 - "${ATESPACE}" "${SECRETS_NAMESPACE}" <<'PY' | k apply -f -
import json, sys
atespace, ns = sys.argv[1], sys.argv[2]
policy = f"policies:\n- atespace: {atespace}\n  allowedNamespaces:\n  - {ns}\n"
print(json.dumps({
    "apiVersion": "v1", "kind": "ConfigMap",
    "metadata": {"name": "k8s-credential-provider-namespace-policy", "namespace": "ate-system"},
    "data": {"namespace-policy.yaml": policy},
}))
PY
  # The provider reads its policy once at startup.
  k -n ate-system rollout restart deployment/k8s-credential-provider
  k -n ate-system rollout status deployment/k8s-credential-provider --timeout=5m
}

grant_hub_access() {
  local member="user:system:serviceaccount:${HUB_NAMESPACE}:herdr-hub"
  # `get access-policy` exits 0 and prints nothing to stdout when the atespace
  # has no policy, so decide by output, not exit status.
  ate get access-policy -a "${ATESPACE}" -o json >"${STATE_DIR}/access-policy.json" 2>/dev/null \
    || die "could not read the access policy of atespace ${ATESPACE}"
  if [[ -s "${STATE_DIR}/access-policy.json" ]]; then
    if grep -q "${member}" "${STATE_DIR}/access-policy.json"; then
      log "hub already has access to ${ATESPACE}"
    else
      die "atespace ${ATESPACE} has its own access policy; add an editor binding for ${member}
(kubectl ate get access-policy -a ${ATESPACE} -o yaml > p.yaml; edit; kubectl ate update access-policy -a ${ATESPACE} -f p.yaml)"
    fi
    return
  fi
  log "granting the hub atespace editor on ${ATESPACE}"
  ATESPACE="${ATESPACE}" HUB_NAMESPACE="${HUB_NAMESPACE}" \
    render "${KIT_DIR}/manifests/hub-access-policy.yaml.tmpl" >"${STATE_DIR}/hub-access-policy.yaml"
  ate create access-policy -a "${ATESPACE}" -f "${STATE_DIR}/hub-access-policy.yaml"
}

cmd_deploy() {
  need kubectl kubectl-ate python3
  local actor_image
  actor_image="$(pinned_image herdr-actor "${ACTOR_IMAGE}" image)"
  # The template trusts the hub's SSH key; .state is per-checkout, so fetch
  # the key from the running hub when the local copy is missing.
  [[ -s "${STATE_DIR}/hub.pub" ]] || hub hubctl pubkey >"${STATE_DIR}/hub.pub" 2>/dev/null || true
  [[ -s "${STATE_DIR}/hub.pub" ]] || { rm -f "${STATE_DIR}/hub.pub"; die "no hub SSH key; run '$0 hub' first"; }
  if [[ "${CREDENTIAL_PROVIDER}" == k8s.io ]]; then
    if agent_enabled claude && [[ -z "$(claude_credential)" ]]; then
      if [[ "${CLAUDE_AUTH}" == oauth-token ]]; then
        die "set CLAUDE_CODE_OAUTH_TOKEN to the token 'claude setup-token' printed (it goes into a Kubernetes Secret, never into the actors)"
      fi
      die "set ANTHROPIC_API_KEY (it goes into a Kubernetes Secret, never into the actors)"
    fi
    if agent_enabled codex && [[ -z "${OPENAI_API_KEY:-}" ]]; then
      die "AGENTS includes codex: set OPENAI_API_KEY (it goes into a Kubernetes Secret, never into the actors)"
    fi
    if agent_enabled agy && [[ -z "${GEMINI_API_KEY:-}" ]]; then
      die "AGENTS includes agy: set GEMINI_API_KEY (it goes into a Kubernetes Secret, never into the actors)"
    fi
  fi

  local worker_image="${WORKER_IMAGE}"
  if [[ -z "${worker_image}" ]]; then
    worker_image="$(k -n ate-demo-counter get workerpool counter -o jsonpath='{.spec.workerImage}' 2>/dev/null || true)"
    [[ "${worker_image}" == *@sha256:* ]] || die "no resolved worker image on ate-demo-counter/counter; run '$0 cluster' first, or set WORKER_IMAGE"
  fi
  [[ "${worker_image}" == *@sha256:* ]] || die "WORKER_IMAGE must be pinned by digest (…/ateworker-gvisor@sha256:…), got ${worker_image}"

  export ATESPACE K8S_NAMESPACE SECRETS_NAMESPACE WORKER_REPLICAS WORKER_NODE_SELECTOR
  export WORKER_IMAGE="${worker_image}"
  export ACTOR_IMAGE="${actor_image}"
  export AUTHORIZED_KEYS_JSON; AUTHORIZED_KEYS_JSON="$(json_quote <"${STATE_DIR}/hub.pub")"
  export AGENT_ENV; AGENT_ENV="$(agent_env_yaml)"

  log "applying WorkerPool (${WORKER_REPLICAS} workers) in namespace ${K8S_NAMESPACE}"
  render "${KIT_DIR}/manifests/workerpool.yaml.tmpl" | k apply -f -
  k -n "${K8S_NAMESPACE}" rollout status deployment/herdr-agents --timeout=10m

  if [[ "${CREDENTIAL_PROVIDER}" == k8s.io ]]; then
    if agent_enabled claude; then
      log "storing the Claude ${CLAUDE_AUTH} in ${SECRETS_NAMESPACE}/anthropic"
      store_secret anthropic "${CREDENTIAL_KEY}" "$(claude_credential)"
    fi
    if agent_enabled codex; then
      log "storing the OpenAI API key in ${SECRETS_NAMESPACE}/openai"
      store_secret openai api-key "${OPENAI_API_KEY}"
    fi
    if agent_enabled agy; then
      log "storing the Gemini API key in ${SECRETS_NAMESPACE}/gemini"
      store_secret gemini api-key "${GEMINI_API_KEY}"
    fi
    grant_secret_namespace
  else
    log "credential provider ${CREDENTIAL_PROVIDER}: credentials stay in its store (${AGENTS})"
  fi

  ate get atespace "${ATESPACE}" >/dev/null 2>&1 || ate create atespace "${ATESPACE}"
  grant_hub_access

  if ate get actor-template "${TEMPLATE_NAME}" -a "${ATESPACE}" >/dev/null 2>&1; then
    warn "template ${ATESPACE}/${TEMPLATE_NAME} exists; templates are immutable, run '$0 down' to replace it"
  else
    log "creating ActorTemplate ${ATESPACE}/${TEMPLATE_NAME}"
    render "${KIT_DIR}/manifests/actor-template.yaml.tmpl" >"${STATE_DIR}/actor-template.yaml"
    ate create actor-template -f "${STATE_DIR}/actor-template.yaml"
    # A new golden snapshot brings a new SSH host key under the pinned alias.
    # shellcheck disable=SC2016 # expanded by the hub's shell, with its own env
    hub sh -c 'ssh-keygen -R "herdr-substrate-${ATESPACE}" -f "${HOME}/.ssh/known_hosts.herdr-substrate"' >/dev/null 2>&1 || true
  fi

  log "waiting for the golden snapshot (first boot of the image under gVisor)"
  local deadline=$((SECONDS + 900)) status tag err
  while :; do
    status="$(ate get actor-template "${TEMPLATE_NAME}" -a "${ATESPACE}" -o json)"
    tag="$(json_get status.goldenSnapshotStatus.goldenTag.name <<<"${status}")"
    err="$(json_get status.goldenSnapshotStatus.errorMessage <<<"${status}")"
    [[ -n "${tag}" ]] && { log "golden snapshot ready (${tag})"; break; }
    [[ -n "${err}" ]] && die "golden snapshot failed: ${err}"
    (( SECONDS < deadline )) || die "timed out waiting for the golden snapshot"
    sleep 5
  done
}

cmd_actor() {
  local name="${1:-}"; [[ -n "${name}" ]] || die "usage: $0 actor <name>"
  validate_name "${name}"
  if ate get actor "${name}" -a "${ATESPACE}" >/dev/null 2>&1; then
    log "actor ${ATESPACE}/${name} exists"
  else
    log "creating actor ${ATESPACE}/${name}"
    ate create actor "${name}" -a "${ATESPACE}" --template "${TEMPLATE_NAME}"
  fi
  # Like access policies, a missing egress policy prints nothing and exits 0.
  local current
  current="$(ate get egress-policy "${name}" -a "${ATESPACE}" -o json 2>/dev/null)" \
    || die "could not read the egress policy of ${ATESPACE}/${name}"
  if [[ -z "${current}" ]]; then
    log "allowing ${name} to reach api.anthropic.com (key injected by the gateway)"
    render_egress_policy "${STATE_DIR}/egress-policy.yaml"
    ate create egress-policy "${name}" -a "${ATESPACE}" -f "${STATE_DIR}/egress-policy.yaml"
  fi
}

cmd_machine() {
  local name="${1:-}"; [[ -n "${name}" ]] || die "usage: $0 machine <name>"
  validate_name "${name}"
  hub hubctl add "${name}"
}

# delete NAME: remove one actor. The herdr machine goes first: an enabled
# machine would reconnect, and every reconnect resumes the actor.
cmd_delete() {
  local name="${1:-}"; [[ -n "${name}" ]] || die "usage: $0 delete <name>"
  validate_name "${name}"
  ate get actor "${name}" -a "${ATESPACE}" >/dev/null 2>&1 || die "no actor ${ATESPACE}/${name}"
  log "removing herdr machine ${name} from the hub"
  hub hubctl remove "${name}" || warn "could not remove the herdr machine ${name}; continuing"
  log "deleting the egress policy and actor ${ATESPACE}/${name}"
  ate delete egress-policy "${name}" -a "${ATESPACE}" >/dev/null 2>&1 || true
  ate delete actor "${name}" -a "${ATESPACE}"
  log "deleted ${ATESPACE}/${name}"
}

cmd_attach() {
  # kubectl exec sends the terminal size only after the session starts, and
  # herdr refuses a 0x0 terminal; so set this terminal's size on the hub's
  # tty first. Later resizes still arrive through kubectl as usual.
  local rows=40 cols=120 size
  size="$(stty size </dev/tty 2>/dev/null || true)"
  if [[ "${size}" =~ ^([0-9]+)\ ([0-9]+)$ ]] && (( BASH_REMATCH[1] > 0 && BASH_REMATCH[2] > 0 )); then
    rows="${BASH_REMATCH[1]}" cols="${BASH_REMATCH[2]}"
  fi
  log "attaching to herdr in the hub (${cols}x${rows}; detach: ctrl+b then q; actors keep running)"
  # shellcheck disable=SC2016 # expanded by the hub's shell
  k -n "${HUB_NAMESPACE}" exec -it deploy/herdr-hub -- \
    sh -c 'stty rows "$1" cols "$2"; shift 2; exec herdr "$@"' sh "${rows}" "${cols}" "$@"
}

# web: the herdr TUI in a browser. ttyd in the hub listens on the pod's
# loopback; this forwards a local port to it, as your kubeconfig identity, so
# whoever may `attach` may use `web` and nobody else. Every tab is its own herdr
# client; closing one only detaches it.
cmd_web() {
  local url="http://localhost:${WEB_PORT}/"
  [[ "${WEB_PORT}" =~ ^[0-9]+$ ]] || die "WEB_PORT must be a port number, got ${WEB_PORT}"
  hub sh -c 'command -v ttyd >/dev/null' \
    || die "this hub image has no web terminal; rebuild it ('$0 hub-image', or a newer HUB_IMAGE) and run '$0 hub'"
  # kubectl itself, not the k() wrapper: $! must be kubectl's pid to stop it.
  kubectl --context "${KUBE_CONTEXT}" -n "${HUB_NAMESPACE}" \
    port-forward --address 127.0.0.1 deploy/herdr-hub "${WEB_PORT}:7681" >/dev/null &
  WEB_PF_PID=$!
  trap 'kill "${WEB_PF_PID}" 2>/dev/null || true' EXIT INT TERM
  local code=000
  for _ in $(seq 1 30); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || true)"
    [[ "${code}" != 000 ]] && break
    kill -0 "${WEB_PF_PID}" 2>/dev/null || die "port-forward failed; is local port ${WEB_PORT} free? (set WEB_PORT)"
    sleep 0.5
  done
  case "${code}" in
    200) ;;
    407) die "the hub's web terminal expects the sign-in header ${HUB_WEB_AUTH_HEADER:-of its proxy}; use your proxy's URL, or 'attach'" ;;
    000) die "the hub's web terminal does not answer; see: kubectl -n ${HUB_NAMESPACE} logs deploy/herdr-hub" ;;
    *) die "the hub's web terminal answered HTTP ${code}" ;;
  esac
  log "herdr in your browser: ${url}  (ctrl+c here stops it; actors keep running)"
  if [[ "${WEB_OPEN:-true}" == "true" ]]; then
    if command -v open >/dev/null; then open "${url}"
    elif command -v xdg-open >/dev/null; then xdg-open "${url}" >/dev/null 2>&1 || true
    fi
  fi
  wait "${WEB_PF_PID}"
}

# verify NAME: from inside actor NAME, call the Anthropic API with the
# placeholder key; success means the egress gateway injected the real key.
cmd_verify() {
  local name="${1:-}"; [[ -n "${name}" ]] || die "usage: $0 verify <name>"
  validate_name "${name}"
  local failed=0
  if agent_enabled claude; then verify_claude "${name}" || failed=1; fi
  if agent_enabled codex; then
    verify_api "${name}" OpenAI "https://api.openai.com/v1/models" \
      "Authorization: Bearer sk-placeholder" '.data' || failed=1
  fi
  if agent_enabled agy; then
    verify_api "${name}" Gemini "https://generativelanguage.googleapis.com/v1beta/models" \
      "x-goog-api-key: placeholder" '.models' || failed=1
  fi
  (( failed == 0 )) || die "${name}: at least one credential was not injected (see above)"
}

# run_in_actor NAME CMD: run CMD in actor NAME, over SSH from the hub.
run_in_actor() {
  # shellcheck disable=SC2016 # expanded by the hub's shell
  hub sh -c 'ssh -F "${HOME}/.ssh/config" -o BatchMode=yes "ate-$1" "$2"' sh "$1" "$2" 2>&1
}

# verify_api NAME LABEL URL HEADER FIELD [EXTRA_HEADER]: list models with a
# placeholder credential; a non-empty list proves the gateway injected the
# real one. Listing models costs nothing.
verify_api() {
  local name="$1" label="$2" url="$3" header="$4" field="$5" extra="${6:-}" out
  local headers="-H '${header}'"
  [[ -z "${extra}" ]] || headers+=" -H '${extra}'"
  log "calling ${url%%/v1*} from ${name} with a placeholder ${label} key"
  out="$(run_in_actor "${name}" "curl -sS --max-time 30 '${url}' ${headers} --cacert /run/ate/trust-bundle.pem")" \
    || { warn "${name}: could not run the ${label} check: ${out:0:300}"; return 1; }
  python3 - "${name}" "${label}" "${field#.}" "${out}" <<'PY'
import json, sys
name, label, field, out = sys.argv[1:]
try:
    data = json.loads(out)
except ValueError:
    sys.exit(f"{name}: unexpected {label} response (egress policy or gateway?):\n{out[:400]}")
models = data.get(field) or []
if models:
    first = models[0].get("id") or models[0].get("name") or "?"
    print(f"OK: {name} reached the {label} API with the injected key ({len(models)} models, e.g. {first})")
else:
    sys.exit(f"{name}: {label} API answered with an error (key not injected?):\n{json.dumps(data)[:400]}")
PY
}

verify_claude() {
  local name="$1" out
  if [[ "${CLAUDE_AUTH}" == oauth-token ]]; then
    # A subscription token is meant for Claude Code, so check with Claude Code:
    # one short reply from the smallest model, with the placeholder token.
    log "asking Claude Code in ${name} for a one-word reply, with the placeholder token"
    out="$(run_in_actor "${name}" "cd /work && CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_AUTH_PLACEHOLDER} NODE_EXTRA_CA_CERTS=/run/ate/trust-bundle.pem timeout 120 claude -p 'Reply with the single word OK.' --model haiku 2>&1")" || true
    if grep -q 'OK' <<<"${out}" && ! grep -qi 'error\|failed' <<<"${out}"; then
      log "OK: ${name} reached Claude with the injected subscription token"
      return 0
    fi
    warn "${name}: Claude Code could not use the injected token (egress policy, token, or plan?): ${out:0:600}"
    return 1
  fi
  verify_api "${name}" Anthropic "https://api.anthropic.com/v1/models" "x-api-key: placeholder" '.data' \
    "anthropic-version: 2023-06-01" || return 1
}

cmd_debug() {
  local name="${1:-}"; [[ -n "${name}" ]] || die "usage: $0 debug <name>"
  ate get actor "${name}" -a "${ATESPACE}" || true
  echo "--- actor logs (only while running)"
  ate logs actor "${name}" -a "${ATESPACE}" 2>&1 | tail -n 40 || true
  echo "--- hub logs"
  k -n "${HUB_NAMESPACE}" logs deploy/herdr-hub --tail=30 || true
  echo "--- ssh -vvv from the hub"
  # shellcheck disable=SC2016 # expanded by the hub's shell
  hub sh -c 'ssh -F "${HOME}/.ssh/config" -vvv -o BatchMode=yes "ate-$1" true' sh "${name}" 2>&1 | tail -n 30 || true
}

cmd_down() {
  local name
  for name in $(ate get actors -a "${ATESPACE}" -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for a in data.get("actors", []):  # protojson omits an empty list
    print(a["metadata"]["name"])' 2>/dev/null); do
    hub hubctl remove "${name}" >/dev/null 2>&1 || true
    ate delete egress-policy "${name}" -a "${ATESPACE}" >/dev/null 2>&1 || true
    ate delete actor "${name}" -a "${ATESPACE}" || true
  done
  ate delete actor-template "${TEMPLATE_NAME}" -a "${ATESPACE}" 2>/dev/null || true
  ate delete access-policy -a "${ATESPACE}" 2>/dev/null || true
  ate delete atespace "${ATESPACE}" 2>/dev/null || true
  k delete namespace "${K8S_NAMESPACE}" "${SECRETS_NAMESPACE}" "${HUB_NAMESPACE}" --ignore-not-found
  k delete clusterrolebinding,clusterrole herdr-hub-trust-bundles --ignore-not-found
  rm -f "${STATE_DIR}/hub.pub"
  log "removed the herdr-substrate deployment; the kind cluster is still up"
  log "delete it with: (cd ${SUBSTRATE_DIR} && hack/delete-kind-cluster.sh)"
}

cmd_up() {
  local names="${*:-luna mars orion}" n
  cmd_cluster
  cmd_image
  cmd_hub_image
  cmd_hub
  cmd_deploy
  for n in ${names}; do cmd_actor "${n}"; done
  for n in ${names}; do cmd_machine "${n}"; done
  hub hubctl status
  log "attach with: $0 attach"
}

# Set dns_lookup_family in the egress gateway's Envoy config to
# EGRESS_DNS_FAMILY, then restart it. Idempotent; re-run it after every
# substrate install or upgrade, which puts substrate's own value back.
cmd_egress_dns() {
  local family="${EGRESS_DNS_FAMILY}"
  if [[ -z "${family}" ]]; then
    log "EGRESS_DNS_FAMILY is empty; leaving the egress gateway's DNS settings as substrate ships them"
    return 0
  fi
  case "${family}" in
    ALL|AUTO|V4_ONLY|V6_ONLY|V4_PREFERRED) ;;
    *) die "EGRESS_DNS_FAMILY must be V4_PREFERRED, ALL, AUTO, V4_ONLY, V6_ONLY or empty (got '${family}')" ;;
  esac
  local cm current patched
  cm="$(k -n ate-system get configmap atenet-egress -o json)" \
    || die "no ConfigMap ate-system/atenet-egress; install substrate first"
  current="$(printf '%s' "${cm}" | python3 -c '
import json, re, sys
conf = json.load(sys.stdin)["data"]["envoy.yaml"]
print(" ".join(sorted(set(re.findall(r"dns_lookup_family:\s*(\w+)", conf)))))')"
  if [[ -z "${current}" ]]; then
    warn "atenet-egress has no dns_lookup_family setting; substrate's config changed, check it by hand"
    return 0
  fi
  if [[ "${current}" == "${family}" ]]; then
    log "egress gateway already resolves with ${family}"
    return 0
  fi
  log "egress gateway: dns_lookup_family ${current} -> ${family}"
  patched="$(printf '%s' "${cm}" | FAMILY="${family}" python3 -c '
import json, os, re, sys
cm = json.load(sys.stdin)
for key in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
    cm["metadata"].pop(key, None)
cm["data"]["envoy.yaml"] = re.sub(r"(dns_lookup_family:\s*)\w+", r"\g<1>" + os.environ["FAMILY"], cm["data"]["envoy.yaml"])
print(json.dumps(cm))')"
  printf '%s' "${patched}" | k replace -f - >/dev/null
  k -n ate-system rollout restart deployment/atenet-egress >/dev/null
  k -n ate-system rollout status deployment/atenet-egress --timeout=180s
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]

  up [names...]     everything below, in order (default actors: luna mars orion)
  check             verify local prerequisites
  cluster           kind cluster + substrate (router allowlists the hub) + demo-counter
  egress-dns        set the egress gateway's DNS family (EGRESS_DNS_FAMILY); cluster runs it
  image             build the actor image, push it to the kind registry
  hub-image         build kubectl-ate and the hub image, push it
  hub               deploy the hub pod; it generates its SSH key
  deploy            WorkerPool, Anthropic Secret, atespace, hub access, ActorTemplate
  actor <name>      create an actor and its egress policy
  machine <name>    save actor <name> as a herdr machine in the hub
  delete <name>     remove actor <name>: herdr machine, egress policy, actor
  attach            herdr TUI inside the hub
  web               the same TUI in your browser, at http://localhost:${WEB_PORT}/
  suspend <name> [--force]
                    via the hub: park the client sessions, cut tunnel, suspend actor
  resume <name>     via the hub: resume actor, wake the client sessions
  status            actors and herdr machines, as the hub sees them
  logs              follow the hub (idle bridge decisions)
  verify <name>     check that actor <name> reaches each agent's API (AGENTS) with injected credentials
  debug <name>      actor state and logs, hub logs, ssh -vvv from the hub
  down              delete actors, template, atespace, hub and namespaces
EOF
}

main() {
  local cmd="${1:-help}"; shift || true
  case "${cmd}" in
    up) cmd_up "$@" ;;
    check) cmd_check ;;
    cluster) cmd_cluster ;;
    egress-dns) cmd_egress_dns ;;
    image) cmd_image ;;
    hub-image) cmd_hub_image ;;
    hub) cmd_hub ;;
    deploy) cmd_deploy ;;
    actor) cmd_actor "$@" ;;
    machine) cmd_machine "$@" ;;
    delete) cmd_delete "$@" ;;
    attach) cmd_attach "$@" ;;
    web) cmd_web ;;
    suspend) [[ -n "${1:-}" ]] || die "usage: $0 suspend <name> [--force]"; hub hubctl suspend "$@" ;;
    resume) [[ -n "${1:-}" ]] || die "usage: $0 resume <name>"; hub hubctl resume "$1" ;;
    status) hub hubctl status ;;
    logs) k -n "${HUB_NAMESPACE}" logs -f deploy/herdr-hub ;;
    verify) cmd_verify "$@" ;;
    debug) cmd_debug "$@" ;;
    down) cmd_down ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}

# Sourcing the script (as test/claude-auth-test.sh does) defines its settings
# and functions without running a command.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
