# Actor image: a herdr server + Claude Code, reachable only through
# SSH-over-WebSocket on port 80 (the one port substrate's router forwards).
#
# Build for the kind registry (setup does this for you):
#   docker buildx build --platform linux/$(go env GOARCH) -t localhost:5001/herdr-actor:dev --push actor/
FROM node:22-bookworm-slim

ARG TARGETARCH
ARG HERDR_VERSION=0.9.5
ARG WEBSOCAT_VERSION=1.14.0
ARG CLAUDE_CODE_VERSION=latest

# openssh-server: the SSH endpoint herdr's saved machines connect to.
# python3 + bash: required by herdr's Claude Code hook script.
# tini: PID 1 that reaps the daemons herdr and sshd leave behind.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server ca-certificates curl git tini python3 bash procps less \
 && rm -rf /var/lib/apt/lists/*

# herdr and websocat: static release binaries, pinned by SHA-256.
# Checksums verified against the v0.9.5 / v1.14.0 GitHub releases on 2026-10-23.
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64; \
             herdr_sha=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d; \
             websocat_sha=8e84d1e3e62bd1cfd42e46a36454c2a58d4d8cca4baa6cb5e7dd7ba2e63cb34b ;; \
      arm64) arch=aarch64; \
             herdr_sha=17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c; \
             websocat_sha=7b554537b7b046caf598a0db4ee95016e4d2899595c71a403d73ff5ad9f0cbed ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/herdr \
      "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${arch}"; \
    echo "${herdr_sha}  /usr/local/bin/herdr" | sha256sum -c -; \
    curl -fsSL -o /usr/local/bin/websocat \
      "https://github.com/vi/websocat/releases/download/v${WEBSOCAT_VERSION}/websocat_max.${arch}-unknown-linux-musl"; \
    echo "${websocat_sha}  /usr/local/bin/websocat" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/herdr /usr/local/bin/websocat

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# Substrate runs the process as UID 0 with only the image ENV (no implicit
# HOME), so set it explicitly.
ENV HOME=/root \
    LANG=C.UTF-8 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Bake herdr's Claude Code hook in: it reports session IDs to the herdr server
# *inside* this actor, so native resume works without crossing the sandbox.
RUN mkdir -p /root/.claude /work \
 && herdr integration install claude

# Skip Claude Code's first-run onboarding. Its setup connectivity check also
# probes platform.claude.com (Console/claude.ai sign-in), which the actor's
# egress policy deliberately blocks; with API-key auth only api.anthropic.com
# is needed. The API key prompt still appears once, for the placeholder key.
RUN printf '{"hasCompletedOnboarding": true}\n' >/root/.claude.json

COPY sshd_config /etc/ssh/sshd_config.d/actor.conf
COPY herdr-config.toml /root/.config/herdr/config.toml
COPY entrypoint.sh /usr/local/bin/herdr-actor-entrypoint
RUN chmod 0755 /usr/local/bin/herdr-actor-entrypoint

WORKDIR /work
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/herdr-actor-entrypoint"]
