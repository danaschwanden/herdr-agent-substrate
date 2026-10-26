# Hub image: the herdr client for all actors plus the lifecycle controller.
# Runs as an ordinary Kubernetes pod (not an actor): it holds the SSH key to
# every actor and ate-api access, which substrate keeps out of sandboxes.
#
# bin/linux-<arch>/kubectl-ate is built from a substrate checkout at the same
# release as the cluster: by `host/herdr-substrate.sh hub-image` for one
# platform, or by .github/workflows/images.yml for each platform it publishes.
FROM debian:bookworm-slim

ARG TARGETARCH
ARG HERDR_VERSION=0.9.5
ARG WEBSOCAT_VERSION=1.14.0
# Web terminal for the herdr TUI (`web`; README: "herdr in the browser").
ARG TTYD_VERSION=1.7.7

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-client openssl ca-certificates curl tini python3 bash procps less tmux \
 && rm -rf /var/lib/apt/lists/*

# Same pinned herdr and websocat as actor/Dockerfile: the hub's herdr must
# match the actors' for saved machines to attach without remote installs.
# ttyd is the hub's alone.
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64; \
             herdr_sha=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d; \
             websocat_sha=8e84d1e3e62bd1cfd42e46a36454c2a58d4d8cca4baa6cb5e7dd7ba2e63cb34b; \
             ttyd_sha=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55 ;; \
      arm64) arch=aarch64; \
             herdr_sha=17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c; \
             websocat_sha=7b554537b7b046caf598a0db4ee95016e4d2899595c71a403d73ff5ad9f0cbed; \
             ttyd_sha=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/herdr \
      "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${arch}"; \
    echo "${herdr_sha}  /usr/local/bin/herdr" | sha256sum -c -; \
    curl -fsSL -o /usr/local/bin/websocat \
      "https://github.com/vi/websocat/releases/download/v${WEBSOCAT_VERSION}/websocat_max.${arch}-unknown-linux-musl"; \
    echo "${websocat_sha}  /usr/local/bin/websocat" | sha256sum -c -; \
    curl -fsSL -o /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${arch}"; \
    echo "${ttyd_sha}  /usr/local/bin/ttyd" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/herdr /usr/local/bin/websocat /usr/local/bin/ttyd

COPY bin/linux-${TARGETARCH}/kubectl-ate /usr/local/bin/kubectl-ate
COPY ate-wss-proxy hubctl herdr-keeper herdr-web-index /usr/local/bin/
COPY herdr-web.js /usr/local/share/herdr-hub/herdr-web.js
# herdr runs `ssh` from PATH; this wrapper hands ate-* client bridges to
# herdr-keeper and everything else to /usr/bin/ssh.
COPY ssh /usr/local/lib/herdr-hub/bin/ssh
COPY entrypoint.sh /usr/local/bin/herdr-hub-entrypoint
COPY herdr-config.toml /etc/herdr-hub/herdr-config.toml
RUN chmod 0755 /usr/local/bin/herdr-keeper /usr/local/bin/herdr-web-index /usr/local/lib/herdr-hub/bin/ssh \
 && chmod 0755 /usr/local/bin/kubectl-ate /usr/local/bin/ate-wss-proxy \
      /usr/local/bin/hubctl /usr/local/bin/herdr-hub-entrypoint

# HOME is the persistent volume (see manifests/hub.yaml.tmpl). Root's passwd
# entry points there too: OpenSSH resolves ~ from the password database, not
# from $HOME, and must find the generated ~/.ssh/config.
# (usermod refuses: the build's own RUN process is root.)
RUN sed -i 's#^\(root:[^:]*:0:0:[^:]*:\)[^:]*:#\1/var/lib/herdr-hub:#' /etc/passwd \
 && test "$(getent passwd root | cut -d: -f6)" = /var/lib/herdr-hub
ENV HOME=/var/lib/herdr-hub LANG=C.UTF-8 TERM=xterm-256color \
    PATH=/usr/local/lib/herdr-hub/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORKDIR /var/lib/herdr-hub
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/herdr-hub-entrypoint"]
