# herdr × agent-substrate

Run coding agents in [agent-substrate](https://github.com/agent-substrate/substrate) actors
(gVisor sandboxes, suspended when idle) and drive all of them from one
[herdr](https://github.com/herdrdev/herdr) client running in a **hub pod** inside the cluster.
No code changes to either project.

The kit comes in three flavours. All three use the same actor and hub images, manifests and
`host/herdr-substrate.sh`; they differ in where the cluster runs and what surrounds it.

**Quick start: this README.** A kind cluster on your own machine, with substrate built from a checkout and
everything in one place: the local registry, PostgreSQL and the snapshot store. Fifteen copy-paste steps take you
from a clean machine to Claude Code running in a sandboxed agent, then through a suspend and resume. Start here.
It's the fastest way to see the whole design work, and the rest of this README applies to every flavour:

- how it works;
- the commands;
- configuration;
- troubleshooting.

**Production on GKE: [docs/production-gke.md](docs/production-gke.md).** The same design on Google
Kubernetes Engine, the platform substrate's installer targets outside kind, hardened for production:

- **Cluster:** regional, with private nodes, and separate node pools for the agents and for substrate's
  control plane.
- **Pinned and managed:** substrate is pinned to a release, its images live in Artifact Registry, and the
  install is a reviewed settings file. State lives in managed services: Cloud SQL without database passwords,
  GCS snapshots each actor can only reach for itself, and the Anthropic key in Secret Manager.
- **Least privilege:** day-to-day work runs as an identity that owns only the agents' area, and the hub is
  locked down like a bastion.

**Production on upstream Kubernetes: [docs/production-kubernetes.md](docs/production-kubernetes.md).** The
same production setup on any conformant Kubernetes 1.37 or later, such as kubeadm, Cluster API, k0s, RKE2 or
Talos:

- **A small patch** on the pinned substrate release swaps its GKE assumptions for S3-compatible object
  storage, your own OpenTelemetry collector, and image pulls that don't depend on GKE's node layout.
- **You provide** a highly available PostgreSQL and a network plugin that enforces NetworkPolicy. The key is
  kept by substrate's Kubernetes Secrets provider, scoped to one namespace.
- **Trade-off:** each agent node holds one credential for the whole snapshot bucket, where GKE scopes it per
  actor. The guide explains what that means.

## Architecture

The quick start's topology is below. The production guides keep the hub, the actors and the three paths into
the cluster as they are. They swap the local registry, in-cluster PostgreSQL and rustfs for external services,
and put the agents and the control plane on their own nodes.

```mermaid
flowchart TB
  subgraph mac["Your machine"]
    you(["You"])
    script["host/herdr-substrate.sh"]
    buildx["docker buildx"]
    registry[("kind-registry<br/>localhost:5001")]
  end
  subgraph kind["kind cluster"]
    subgraph sys["ate-system: substrate control plane"]
      api["ate-api-server<br/>gRPC control API"]
      pg[("postgres<br/>actors, templates, policies")]
      router["atenet-router<br/>ingress, mTLS"]
      egress["atenet-egress<br/>egress gateway"]
      cred["k8s-credential-provider"]
      atelet["atelet<br/>per node"]
      store[("rustfs<br/>snapshots")]
    end
    podcert["podcertificate-controller<br/>issues pod identities"]
    subgraph hubns["herdr-hub"]
      hub["hub pod<br/>herdr client, hubctl idle-watch,<br/>ate-wss-proxy, SSH key on PVC"]
    end
    subgraph agents["herdr-agents: WorkerPool"]
      subgraph worker["worker pod"]
        actor["actor in a gVisor sandbox<br/>websocat :80, sshd, herdr server,<br/>claude in panes"]
      end
    end
    secret[("Secret anthropic<br/>herdr-agents-secrets")]
  end
  anthropic(["api.anthropic.com"])

  you -->|"attach: kubectl exec"| hub
  script -->|"kubectl, kubectl ate"| api
  script --> buildx -->|"push images"| registry
  registry -.->|"pull"| worker
  registry -.->|"pull"| hub
  podcert -.->|"SPIFFE client certificate"| hub
  hub -->|"SSH over WebSocket, mTLS"| router
  hub -->|"suspend, resume, list"| api
  router -->|"ResumeActor"| api
  router -->|"tunnel to the actor's port 80"| actor
  api --- pg
  atelet -->|"restore and snapshot"| actor
  atelet --- store
  actor -->|"HTTPS with placeholder key"| egress
  egress -->|"look up credential"| cred
  cred --- secret
  egress -->|"HTTPS with real key"| anthropic
```

- **Your machine** runs the setup script and Docker. In the quick start, images go to a local registry the
  cluster pulls from.
- **ate-system** is substrate's control plane: the API (state in postgres), the router (the only way into an actor),
  the egress gateway (the only way out), atelet (snapshots, stored in rustfs) and the credential provider.
- **The hub** is an ordinary pod: the herdr client for every actor and the lifecycle controller.
- **Each actor** runs in a gVisor sandbox on a worker pod: a herdr server behind sshd behind websocat, with Claude
  Code in its panes. Its only egress is `api.anthropic.com`, and the real API key is added on the way out.

Built against herdr **0.9.5**. The quick start tracks substrate's `main` and was tested at commit **4ebd668**
(2026-10-23); the production guides pin substrate release **v0.6.0**.

## Quick start on kind

A complete walkthrough on your own machine, from a clean setup to Claude Code running in a sandboxed actor,
then a suspend/resume round trip. Every command block can be pasted into a terminal as is (bash or zsh). Run
everything from the kit's directory unless a step says otherwise.

It's meant for trying the kit out and for development. For a shared or long-lived installation, follow
[Production on GKE](docs/production-gke.md) or [Production on upstream Kubernetes](docs/production-kubernetes.md)
instead. They prepare the cluster and substrate their own way, then use the same commands as steps 8 to 13 here.

### 1. Prepare Docker

This setup builds several large images and runs a full control plane, and a full Docker disk shows up as
unrelated-looking crashes later. In **Docker Desktop → Settings → Resources**, set:

- **Memory:** 12 GB or more
- **CPUs:** 6 or more
- **Disk usage limit:** 100 GB or more

Then apply, and start from an empty build cache:

```bash
docker builder prune -a -f
```

On Linux with Docker Engine, make sure the disk holding `/var/lib/docker` has 60 GB or more free.

### 2. Install the tools

macOS with Homebrew:

```bash
brew install go kubectl git
```

You also need `python3`, which macOS provides with the Xcode command line tools (`xcode-select --install`).
substrate needs Go 1.27 or newer; with an older Go it downloads the right toolchain automatically. `kind` is
fetched by substrate's own scripts. herdr, websocat and OpenSSH are **not** needed on your machine: they run in
the hub.

Put Go's install directory on your `PATH`, so you can also run `kubectl ate` yourself:

```bash
export PATH="$(go env GOPATH)/bin:$PATH"
```

To make that permanent, add the same line to `~/.zshrc` (or `~/.bashrc`).

### 3. Get the code

Unpack this kit, `cd` into it, then clone substrate next to it (the kit expects `../substrate`):

```bash
git clone https://github.com/agent-substrate/substrate ../substrate
```

### 4. Configure

```bash
cp .env.example .env
```

Add your Anthropic API key. You are prompted for it, so it doesn't end up in your shell history:

```bash
printf 'Anthropic API key: '; read -rs key; printf '\nANTHROPIC_API_KEY=%s\n' "$key" >> .env; unset key
```

On Docker Desktop, select its `docker`-driver builder for image pushes to the kind registry:

```bash
echo 'BUILDX_BUILDER=desktop-linux' >> .env
```

On Linux, use `BUILDX_BUILDER=default` instead. Run `docker buildx ls` to see your builders: the one used
must have the `docker` driver.

### 5. Start clean (only if you ran this kit before)

This deletes the kind cluster and its local registry, and the kit's local state:

```bash
(cd ../substrate && hack/delete-kind-cluster.sh)
```

```bash
rm -rf .state
```

### 6. Check prerequisites

```bash
host/herdr-substrate.sh check
```

It ends with `prerequisites ok`. It stops with a clear message if the builder has the wrong driver, a tool is
missing, or the substrate checkout isn't found.

### 7. Create the cluster and install substrate

```bash
host/herdr-substrate.sh cluster
```

This is the long step: 15–30 minutes the first time, mostly substrate building its Envoy router image. It
creates the kind cluster and registry, installs substrate with the hub's identity on the router's allowlist,
deploys substrate's counter demo (only to reuse its worker image; its workers are scaled to 0), and installs
`kubectl-ate`. It ends by reporting Docker's free disk space.

Check that the control plane is healthy before continuing; every pod in `ate-system` should be fully ready
(`2/2`, `1/1`, …) except `rustfs-bucket-init`, which is `Completed`:

```bash
kubectl -n ate-system get pods
```

### 8. Build the images

```bash
host/herdr-substrate.sh image
```

```bash
host/herdr-substrate.sh hub-image
```

Each ends with a line like `herdr-actor: localhost:5001/herdr-actor@sha256:…`.

If your copy of the kit is on GitHub with its image workflow enabled, you can skip this step and use the
published images instead ([Prebuilt images](#prebuilt-images-from-github)).

### 9. Deploy the hub

```bash
host/herdr-substrate.sh hub
```

Ends with `hub SSH key: ssh-ed25519 …`. The hub generated that key itself; it never leaves the cluster.

### 10. Deploy the agent template

```bash
host/herdr-substrate.sh deploy
```

Creates the worker pool, stores your API key as a Kubernetes Secret, lets the egress gateway read it, creates
the `herdr-agents` atespace with editor rights for the hub, and creates the actor template. It then waits for
the **golden snapshot**, the first boot of the actor image under gVisor (a few minutes), and ends with
`golden snapshot ready`.

### 11. Create an actor and add it to herdr

```bash
host/herdr-substrate.sh actor luna
```

```bash
host/herdr-substrate.sh machine luna
```

`machine` connects from the hub through the router into the actor and saves it as a herdr machine. It ends
with `Saved SSH machine … Remote server is ready.` Repeat both commands with other names for more actors.

### 12. Verify

```bash
host/herdr-substrate.sh status
```

Shows `luna` as `ACTOR_STATE_RUNNING` with a worker pod, and the herdr machine `luna … enabled`.

```bash
host/herdr-substrate.sh verify luna
```

Calls the Anthropic API from inside `luna` with the placeholder key. `OK: luna reached the Anthropic API with
the injected key` proves the egress gateway substitutes the real key.

### 13. Run Claude Code in the actor

```bash
host/herdr-substrate.sh attach
```

In herdr, select **luna** in the sidebar and open a workspace or tab on it (`+`). At the `#` prompt, run:

```bash
claude
```

Claude Code asks once whether to use the API key from the environment: answer **yes**. That key is the
placeholder; the real one never enters the actor. Give it a small task, and watch its state (working, idle)
in herdr's sidebar.

Detach with `ctrl+b` then `q`. Claude and the actor keep running.

### 14. Suspend and resume

The hub suspends an actor automatically after 5 minutes (`IDLE_SECONDS`) with no working or blocked agent,
including an actor with no agents at all. To do it by hand:

```bash
host/herdr-substrate.sh suspend luna
```

```bash
host/herdr-substrate.sh status
```

`luna` is now `ACTOR_STATE_SUSPENDED` with no worker pod, and its herdr machine is `disabled`. Its memory,
including the running Claude session, is in a snapshot.

```bash
host/herdr-substrate.sh resume luna
```

```bash
host/herdr-substrate.sh attach
```

`luna` is running and enabled again, and the Claude session is where you left it. To watch the hub's
automatic decisions (Ctrl-C to stop):

```bash
host/herdr-substrate.sh logs
```

### 15. Tear down

Remove a single actor, including its snapshot:

```bash
host/herdr-substrate.sh delete luna
```

Remove all actors, the template, hub and namespaces, keeping the cluster:

```bash
host/herdr-substrate.sh down
```

Or delete everything, including the cluster and registry:

```bash
(cd ../substrate && hack/delete-kind-cluster.sh)
```

### One-shot alternative

Steps 6–11 in one command, creating actors `luna`, `mars` and `orion` (pass names to choose your own):

```bash
host/herdr-substrate.sh up
```

The step-by-step path above is easier to diagnose the first time.

## How it works

This applies to every flavour. The production guides change where components run and where state is kept,
not how the hub, the actors and substrate interact. Where a diagram shows a quick-start detail (the local
registry, a kind node), the guides name what replaces it.

### Life of an actor

From `actor luna` to Claude's first request, and back to sleep. The numbers match the steps below.

```mermaid
sequenceDiagram
  autonumber
  actor U as You
  participant S as herdr-substrate.sh
  participant A as ate-api
  participant H as hub pod
  participant R as atenet-router
  participant W as atelet and worker
  participant X as actor luna
  participant E as egress gateway
  participant C as credential provider
  participant M as api.anthropic.com

  rect rgba(128,128,128,0.08)
  Note over U,A: actor luna
  U->>S: actor luna
  S->>A: CreateActor luna from template herdr-agent
  A-->>S: SUSPENDED, points at the golden snapshot
  S->>A: CreateActorEgressPolicy: api.anthropic.com only, x-api-key injection
  end

  rect rgba(128,128,128,0.08)
  Note over U,X: machine luna: first connection
  U->>S: machine luna
  S->>H: kubectl exec: hubctl add luna
  H->>R: ssh ate-luna via ate-wss-proxy<br/>wss, pod certificate, ate-target-actor herdr-agents/luna
  R->>R: SPIFFE ID on the allowlist?
  R->>A: ResumeActor luna, request held meanwhile
  A->>W: claim a free worker, restore the golden snapshot
  W->>X: restore memory into a gVisor sandbox<br/>websocat, sshd and herdr server are already running
  A-->>R: RUNNING on worker pod
  R->>X: mTLS tunnel via atunnel to port 80
  X->>X: websocat to sshd on 127.0.0.1:2222
  H->>X: herdr --version, then herdr machine add
  X-->>H: remote herdr server ready
  end

  rect rgba(128,128,128,0.08)
  Note over U,M: attach, then claude in a pane
  U->>H: attach: herdr TUI in the hub
  H->>X: herdr session over the same SSH path
  X->>X: pane runs claude, onboarding pre-completed
  X->>X: DNS relay resolves api.anthropic.com, allowed by policy
  X->>E: HTTPS, x-api-key placeholder
  E->>E: terminate TLS, the actor trusts the gateway CA
  E->>C: credential ate-secret://k8s.io/.../anthropic/api-key
  C->>C: atespace herdr-agents may read herdr-agents-secrets?
  C-->>E: real API key
  E->>M: same request, real x-api-key
  M-->>X: model response, back through the gateway
  end

  rect rgba(128,128,128,0.08)
  Note over H,W: 5 minutes without a working or blocked agent
  H->>H: idle-watch: herdr machine disable luna, kill tunnel
  H->>A: SuspendActor luna
  A->>W: checkpoint memory to a snapshot, free the worker
  A-->>H: SUSPENDED
  end
```

- **Creation (1–4)** only writes records: a new actor is `SUSPENDED` and points at the template's golden snapshot,
  so it uses no worker until something connects.
- **First connection (5–16).** The hub's SSH connection reaches the router, which checks the hub's identity and
  holds the request while ate-api claims a worker and atelet restores the golden snapshot. sshd, websocat and the
  herdr server were running when the snapshot was taken, so they are running again immediately.
- **First Claude request (17–27).** The actor can resolve and reach only `api.anthropic.com`. The egress gateway
  terminates its TLS (the actor trusts the gateway's CA), looks up the credential the egress policy names, and
  replaces the placeholder `x-api-key` with the real one.
- **Back to sleep (28–31).** After `IDLE_SECONDS` without a working or blocked agent, the hub disables the machine
  first, so no client reconnects and wakes it, then suspends it. The next resume restores this actor's own
  snapshot, with its Claude session intact.

### Two roles, two lifecycles

| | Server actors (the agents) | Hub pod (herdr client + controller) |
|---|---|---|
| Runs as | substrate actor, gVisor sandbox | ordinary Kubernetes Deployment, 1 replica |
| Count | many; fewer workers than actors | one |
| Busy when | an agent is working | always, but tiny: a 30 s poll loop |
| Sleeps | suspended after `IDLE_SECONDS` with no working or blocked agent | doesn't; scale it to 0 if you like, its state is on its volume |
| Wakes | next connection through the router, or `resume` | `attach` / `kubectl exec` |
| State | agent sessions, in memory snapshots | herdr machine list, SSH key, known_hosts, idle timers (1 GiB PVC) |
| Holds | nothing privileged; a placeholder API key | the SSH key to every actor, atespace editor on ate-api, a router identity |

#### Why the client is a pod, not an actor

- **Actors can't open streams.** Substrate's egress allows HTTP(S) requests only; WebSocket, `CONNECT` and any
  other TCP are blocked (`docs/egress-traffic.md`). Herdr's machine connections are long-lived SSH streams, so a
  client actor could never reach the server actors.
- **The client is the trust anchor.** It holds keys to every actor and ate-api access. Substrate treats actors as
  untrusted and keeps credentials and control-plane access out of them.
- **The router admits only allowlisted identities.** The Envoy router requires `--ingress-allowed-spiffe-ids` and
  accepts only clients with an mTLS certificate carrying an allowlisted SPIFFE ID. A pod gets one from substrate's
  pod-identity signer; a laptop with a port-forward has none.
- **The lifecycles are coupled through the client.** An enabled herdr machine is reconnected by any open client,
  and every reconnect resumes its actor. So whatever owns the machine list must also be what suspends actors. In
  the hub, `hubctl` does both.

### Lifecycle

`hubctl idle-watch` runs as a service in the hub. Every `POLL_SECONDS` it asks each *enabled* actor machine for
its agents (`herdr --machine <actor> agent list`). An actor with no `working` or `blocked` agent for
`IDLE_SECONDS` is suspended:

1. `herdr machine disable`: no client may reconnect, since each reconnect would resume the actor.
2. The actor's websocat tunnel is killed; herdr's SSH master would otherwise linger (`ControlPersist=600`).
3. `kubectl-ate suspend actor`, as `system:serviceaccount:herdr-hub:herdr-hub` (atespace editor).

`resume <actor>` resumes explicitly and re-enables the machine. Suspended machines are skipped by the idle bridge
and refused by `herdr --machine`, so nothing in the hub wakes an actor except an explicit resume.


#### Actor states

An actor's substrate state and its herdr machine's state move together; the hub keeps them in step.

```mermaid
stateDiagram-v2
  state "SUSPENDED, no herdr machine" as S0
  state "RUNNING, no herdr machine" as R0
  state "RUNNING, machine enabled" as RE
  state "SUSPENDED, machine disabled" as SD
  state "RUNNING, machine disabled" as RD

  [*] --> S0: actor NAME
  S0 --> R0: machine NAME, first ssh
  R0 --> RE: herdr machine add
  RE --> SD: idle or suspend NAME
  SD --> RE: resume NAME
  SD --> RD: router connection
  RD --> RE: resume NAME
  RD --> SD: suspend NAME
  RE --> [*]: delete NAME
  SD --> [*]: delete NAME
  RD --> [*]: delete NAME
```

- `actor NAME` creates the actor suspended, from the golden snapshot. `machine NAME`'s first ssh goes through the
  router, which resumes it, and then registers it with herdr.
- *Idle or `suspend NAME`* runs three steps in order: disable the machine, kill the websocat tunnel, then
  `SuspendActor` (the snapshot uploads in the background). A working or blocked agent resets the idle timer.
- *RUNNING, machine disabled* is the state to watch for. Any connection through the router wakes an actor
  (`verify`, `debug`, or an ssh you ran by hand), but its machine stays disabled, and the idle bridge only looks at
  enabled machines, so **the hub never suspends it on its own**. Run `resume NAME` to hand it back to the idle
  bridge, or `suspend NAME` to put it back to sleep.
- `delete NAME` works from any state.

### Trust and identity

Every credential in the system, who holds it, and who checks it.

```mermaid
flowchart LR
  subgraph laptop["Your machine"]
    KC["kubeconfig<br/>kind cluster admin"]
    ENV[".env<br/>real API key"]
  end

  subgraph hub["Hub pod: holds the keys"]
    CERT["client certificate<br/>SPIFFE ID herdr-hub/herdr-hub<br/>rotated by the kubelet"]
    TOK["ServiceAccount token<br/>audience api.ate-system.svc"]
    SSHK["SSH private key<br/>on the PVC, never leaves"]
    KH["known_hosts"]
  end

  subgraph cp["Control plane: checks identities"]
    RT["atenet-router<br/>SPIFFE allowlist"]
    API["ate-api<br/>access policy: hub is editor<br/>on herdr-agents"]
  end

  subgraph actor["Actor: untrusted, holds nothing"]
    AK["authorized_keys<br/>hub public key only"]
    HK["SSH host key"]
    PH["placeholder API key<br/>egress-mitm trust bundle"]
  end

  subgraph eg["Egress: swaps the key"]
    EGW["egress gateway<br/>replaceHeaders x-api-key"]
    CRED["credential provider<br/>herdr-agents may read<br/>herdr-agents-secrets"]
    SEC[("Secret anthropic")]
  end

  KC -- "path 1: TokenRequest ate-client" --> API
  CERT -- "mTLS" --> RT
  TOK -- "bearer" --> API
  SSHK -- "public half in the template" --> AK
  KH -. "pins" .-> HK
  PH -- "HTTPS" --> EGW
  EGW --> CRED --> SEC
  ENV -- "deploy writes" --> SEC
```

- **The hub holds the keys.** Its router identity (a short-lived certificate from substrate's pod-identity signer),
  its ate-api token and the SSH private key all live in the hub pod and never leave the cluster.
- **The control plane checks identities.** The router admits only the hub's SPIFFE ID; ate-api grants the hub
  editor rights on `herdr-agents` and nothing else. In the quick start, your machine reaches ate-api as the
  bootstrap owner, via path 1. In production you act as `herdr-operator`, which owns only `herdr-agents`.
- **Actors hold nothing worth stealing.** An actor has the hub's *public* key, its own host key (pinned by the hub
  on first connect) and a placeholder API key.
- **The real API key stays in a Secret.** The egress gateway decrypts the actor's HTTPS (the actor trusts its
  `egress-mitm` bundle), asks the credential provider for the key and replaces the `x-api-key` header.

### Network and ports

Every listener, and which hop crosses which port.

```mermaid
flowchart TB
  subgraph laptop["Your machine"]
    SH["herdr-substrate.sh<br/>kubectl, kubectl-ate"]
    REG["kind-registry<br/>localhost:5001"]
  end

  KAPI["kube-apiserver<br/>127.0.0.1:host port → 6443"]

  subgraph hubns["herdr-hub namespace"]
    HC["herdr client<br/>Unix socket"]
    PX["ate-wss-proxy<br/>ssh ProxyCommand"]
    HCTL["hubctl"]
  end

  subgraph ate["ate-system"]
    RTR["atenet-router.ate-system.svc:443<br/>Envoy, mTLS + WSS"]
    APISVC["api.ate-system.svc:443<br/>headless"]
    EGW["egress gateway + DNS relay<br/>HTTPS only"]
  end

  subgraph worker["worker, gVisor actor"]
    WS["websocat 0.0.0.0:80"]
    SSHD["sshd 127.0.0.1:2222"]
    HS["herdr server<br/>Unix socket"]
    CL["claude"]
  end

  ANT["api.anthropic.com:443"]

  SH -- "kubectl, exec, port-forward" --> KAPI
  KAPI -. "port-forward gRPC" .-> APISVC
  REG -. "image pulls" .-> worker
  HC -- "ssh ate-NAME" --> PX
  PX -- "WSS :443" --> RTR
  HCTL -- "gRPC :443" --> APISVC
  RTR -- "ResumeActor" --> APISVC
  RTR -- "atunnel → :80" --> WS
  WS -- "TCP" --> SSHD
  SSHD -- "herdr remote session" --> HS
  HS --> CL
  CL -- "HTTPS :443" --> EGW
  EGW -- "real key injected" --> ANT
```

- In the quick start, nothing listens on your machine except the kind registry (`localhost:5001`) and
  kube-apiserver's mapped port. In production, nothing listens on it at all.
- Inside an actor only websocat listens on all interfaces (port 80, the one port the router forwards). sshd is on
  loopback, and herdr uses a Unix socket.
- Actor egress is HTTPS only, through the gateway. The DNS relay answers NXDOMAIN for hosts outside the egress
  policy, so an actor can't even resolve names it isn't allowed to reach.

## Commands

`host/herdr-substrate.sh <command>`. Every step is idempotent and can be re-run.

The same commands drive every flavour. `cluster` and `up` exist only in the quick start, where they create the
kind cluster and install substrate. The production guides set up the cluster and substrate themselves, then point
the script at it through `.env` ([Configuration](#configuration)). The script's disk check and builder check
only apply to the kind registry.

| Command | What it does |
|---|---|
| `check` | tools, substrate checkout, Docker reachable, buildx builder driver, free disk space (once the cluster exists) |
| `cluster` | substrate's `create-kind-cluster.sh`; `install-ate-kind.sh deploy ate-system` with the k8s.io credential provider and the hub in `ATE_INGRESS_ALLOWED_SPIFFE_IDS`; `deploy demo counter` (scaled to 0 workers, used for its worker image); `go install ./cmd/kubectl-ate` |
| `image` | builds `actor/`, pushes to `REGISTRY` (`localhost:5001`), records the digest (templates must be digest-pinned). Not needed with a prebuilt `ACTOR_IMAGE` |
| `hub-image` | cross-builds `kubectl-ate` from your substrate checkout into `hub/bin/linux-<arch>/`, builds and pushes `hub/`. Not needed with a prebuilt `HUB_IMAGE` |
| `hub` | applies `manifests/hub.yaml.tmpl`; waits for the hub's SSH key |
| `deploy` | WorkerPool, Anthropic Secret + credential-provider grant, atespace, hub access policy, ActorTemplate trusting the hub key; waits for the golden snapshot |
| `actor <name>` | creates the actor and its egress policy |
| `machine <name>` | `hubctl add <name>` in the hub: pins the host key, `herdr machine add` |
| `delete <name>` | removes one actor: its herdr machine (first, so nothing reconnects and resumes it), its egress policy, the actor and its snapshot |
| `verify <name>` | calls the Anthropic API from inside the actor with the placeholder key |
| `attach` | herdr TUI in the hub, sized to your terminal |
| `suspend <name>` / `resume <name>` | `hubctl` in the hub (see [Lifecycle](#lifecycle)) |
| `status` | actors and herdr machines, as the hub sees them |
| `logs` | follows the hub: idle-bridge decisions |
| `debug <name>` | actor state and logs, hub logs, `ssh -vvv` from the hub |
| `down` | deletes actors, template, access policy, atespace, hub and namespaces; keeps the cluster |
| `up [names…]` | `cluster` through `machine`, for the given actors (default `luna mars orion`) |


### Three paths into the cluster

Every command reaches the cluster in one of three ways.

```mermaid
sequenceDiagram
  autonumber
  participant S as herdr-substrate.sh
  participant K as kube-apiserver
  participant A as ate-api
  participant H as hub pod
  participant R as atenet-router
  participant X as actor

  rect rgba(128,128,128,0.08)
  Note over S,A: Path 1: your machine to ate-api, kubectl ate without --endpoint
  S->>K: TokenRequest for ServiceAccount ate-system/ate-client
  S->>K: port-forward to an ate-api-server pod
  S->>K: read the servicedns ClusterTrustBundle
  S->>A: gRPC through the port-forward, TLS, bearer token, as the bootstrap owner
  end

  rect rgba(128,128,128,0.08)
  Note over H,A: Path 2: hub to ate-api, hubctl
  H->>K: read the servicedns ClusterTrustBundle, allowed by ClusterRole herdr-hub-trust-bundles
  H->>A: gRPC to api.ate-system.svc:443, projected ServiceAccount token<br/>as herdr-hub:herdr-hub, atespace editor on herdr-agents
  end

  rect rgba(128,128,128,0.08)
  Note over H,X: Path 3: hub to an actor, ssh ate-NAME
  H->>R: ate-wss-proxy: wss://atenet-router.ate-system.svc:443<br/>client certificate from the podidentity signer, ate-target-actor header
  R->>R: SPIFFE ID allowlisted? actor exists?
  R->>A: ResumeActor, only if suspended
  R->>X: mTLS tunnel to atunnel on the worker, then the actor's port 80
  X->>X: websocat to sshd 127.0.0.1:2222, hub key only
  end
```

- **Path 1** is how *you* talk to ate-api. `kubectl ate` mints a token for substrate's `ate-client` ServiceAccount,
  which a quick-start install makes a bootstrap owner, and tunnels to the API through a port-forward. The
  production guides set `ATE_CLIENT_SERVICE_ACCOUNT=herdr-operator`, so the same path runs as an identity that
  owns only the herdr atespace.
- **Path 2** is how the *hub* talks to ate-api: directly, inside the cluster, with its own projected token and
  only atespace-editor rights on `herdr-agents`.
- **Path 3** is the only way into an actor. The router admits only allowlisted SPIFFE identities, so only the hub
  can use it; your machine never connects to an actor directly.

### What each command uses

```mermaid
flowchart LR
  subgraph cmds["herdr-substrate.sh"]
    c1["check<br/>image, hub-image"]
    c2["cluster"]
    c3["hub<br/>deploy: WorkerPool, Secret, policy"]
    c4["deploy: atespace, template<br/>actor, delete, down"]
    c5["machine, suspend, resume<br/>status, verify, debug"]
    c6["attach"]
    c7["logs"]
  end
  docker["docker, buildx"]
  registry[("kind-registry")]
  substrate["substrate scripts<br/>create-kind-cluster.sh<br/>install-ate-kind.sh: ate-setup"]
  kubectl["kubectl"]
  kate["kubectl ate<br/>path 1"]
  hubctl["hubctl in the hub<br/>paths 2 and 3"]
  herdr["herdr TUI in the hub<br/>path 3"]
  kapi["kube-apiserver"]
  api["ate-api"]
  actor["actors"]

  c1 --> docker --> registry
  c2 --> substrate --> kapi
  c3 --> kubectl --> kapi
  c4 --> kate --> api
  c5 -->|"kubectl exec"| hubctl
  hubctl --> api
  hubctl --> actor
  c6 -->|"kubectl exec -it"| herdr --> actor
  c7 -->|"kubectl logs"| kapi
```

#### `check`

Read-only. Checks the tools on your `PATH`, the substrate checkout, that Docker answers, that the active buildx
builder uses the `docker` driver (`docker buildx inspect`), and, once the cluster exists, the free space on
Docker's disk (`df` in the kind node).

#### `cluster`

Runs substrate's own kind tooling; `install-ate-kind.sh` is a wrapper around substrate's installer, `ate-setup`.

```mermaid
sequenceDiagram
  autonumber
  participant S as herdr-substrate.sh
  participant D as Docker
  participant T as substrate scripts and ate-setup
  participant K as kind cluster
  S->>D: check: tools, daemon, buildx driver
  S->>T: create-kind-cluster.sh
  T->>D: kind-registry container on localhost:5001, kind node
  S->>T: install-ate-kind.sh deploy ate-system<br/>k8s.io credential provider, hub SPIFFE ID allowlisted
  T->>T: build images with ko and buildx, including the Envoy router
  T->>K: apply CRDs, ate-api, controller, atelet, router, egress gateway,<br/>credential provider, podcertificate-controller, postgres, rustfs
  S->>T: install-ate-kind.sh deploy demo counter
  T->>K: counter WorkerPool with a built ateworker-gvisor image
  S->>K: kubectl patch: counter workers to 0 replicas
  S->>S: go install kubectl-ate, report free disk space
```

The router allowlist is fixed at install time, which is why this step, not `hub`, puts the hub's SPIFFE ID on
it. Re-running `cluster` recreates the cluster from scratch.

#### `image` and `hub-image`

```mermaid
sequenceDiagram
  autonumber
  participant S as herdr-substrate.sh
  participant B as docker buildx
  participant G as kind-registry
  S->>S: check builder driver and disk space
  opt hub-image only
    S->>S: go build kubectl-ate for linux into hub/bin
  end
  S->>B: build actor/ or hub/ for this machine's architecture
  B->>B: verify pinned SHA-256 of herdr and websocat
  B->>G: push NAME:dev
  S->>G: HEAD manifest when buildx metadata has no digest
  S->>S: record NAME@sha256 in .state
```

Templates and Deployments reference images by digest, so the digest is recorded in `.state/` for `hub` and
`deploy`. `hub-image` builds `kubectl-ate` from your substrate checkout, so the hub's client matches the cluster.

#### `hub`

```mermaid
sequenceDiagram
  autonumber
  participant S as herdr-substrate.sh
  participant K as kube-apiserver
  participant L as kubelet
  participant P as podcertificate-controller
  participant H as hub pod
  S->>K: apply hub.yaml: namespace with ate.dev/api-access, ServiceAccount,<br/>ClusterTrustBundle RBAC, PVC, Deployment
  L->>P: PodCertificateRequest for herdr-hub:herdr-hub
  P-->>L: signed certificate, SPIFFE ID spiffe://cluster.local/ns/herdr-hub/sa/herdr-hub
  L-->>H: projected client certificate and key, rotated before expiry
  L-->>H: projected servicedns trust bundle and ate-api token
  H->>H: entrypoint: generate SSH key on the PVC, write ssh config<br/>start hubctl idle-watch
  S->>H: kubectl exec: hubctl pubkey
  H-->>S: public key, stored in .state/hub.pub
```

Uses kubectl only. The hub's identity comes entirely from Kubernetes: its ServiceAccount gives it a SPIFFE
certificate for the router and a token for ate-api, and its namespace label lets ate-system's NetworkPolicy admit
it. The SSH private key is created inside the pod and never leaves its volume.

#### `deploy`

```mermaid
sequenceDiagram
  autonumber
  participant S as herdr-substrate.sh
  participant K as kube-apiserver
  participant A as ate-api
  participant W as worker
  S->>K: WorkerPool herdr-agents, worker image from the counter pool
  S->>K: Secret anthropic in herdr-agents-secrets
  S->>K: credential-provider policy: herdr-agents may read herdr-agents-secrets<br/>then restart the provider
  S->>A: CreateAtespace herdr-agents
  S->>A: CreateAtespaceAccessPolicy: editor for herdr-hub:herdr-hub
  S->>A: CreateActorTemplate herdr-agent: image digest, hub public key,<br/>capabilities, trust bundle, memory snapshots
  A->>W: template reconciler boots a golden actor
  W->>W: entrypoint: host key, PTY self-test, sshd, herdr server, websocat
  A->>A: memory snapshot tagged as the golden snapshot
  loop every 5 s, up to 15 min
    S->>A: GetActorTemplate: golden tag set?
  end
```

Kubernetes objects go through kubectl; substrate objects (atespace, access policy, template) through path 1.
Each step checks what already exists, so re-running is safe; templates are immutable, so changing the image or
key means `down` and `deploy` again.

#### `actor <name>`

Path 1 only: `CreateActor`, then `CreateActorEgressPolicy` allowing `api.anthropic.com` with key injection
(steps 1–4 of [Life of an actor](#life-of-an-actor)). The actor stays suspended and uses no worker until something
connects.

#### `machine <name>`

`kubectl exec` into the hub, which runs `hubctl add`: a first `ssh ate-<name>` over path 3, which resumes the
actor and pins its host key, then `herdr machine add`, which checks the actor's herdr server and saves it. These
are steps 5–16 of [Life of an actor](#life-of-an-actor).

#### `attach`

```mermaid
sequenceDiagram
  autonumber
  actor U as You
  participant S as herdr-substrate.sh
  participant H as hub pod
  participant X as actors
  U->>S: attach
  S->>S: read your terminal size
  S->>H: kubectl exec -it: stty rows and cols, then herdr
  H->>H: herdr starts and loads the saved machines
  H->>X: one SSH session per enabled machine, path 3
  X-->>H: workspaces, panes, agent states
  U->>H: ctrl+b then q detaches, the actors keep running
```

herdr connects only to *enabled* machines and only while a client is attached, so leaving the hub unattended
doesn't keep actors awake.

#### `verify <name>`

```mermaid
sequenceDiagram
  autonumber
  participant S as herdr-substrate.sh
  participant H as hub pod
  participant X as actor
  participant E as egress gateway
  participant M as api.anthropic.com
  S->>H: kubectl exec: ssh ate-NAME
  H->>X: path 3, resumes the actor if needed
  X->>E: curl /v1/models, x-api-key placeholder, gateway CA
  E->>M: real key injected
  M-->>X: model list, back through the gateway
  X-->>S: curl output via the hub, printed as OK or the error
```

The same path Claude's requests take, without Claude: it separates network and credential problems from
Claude Code problems.

#### `suspend <name>` and `resume <name>`

```mermaid
sequenceDiagram
  autonumber
  participant S as herdr-substrate.sh or idle-watch
  participant H as hub pod
  participant A as ate-api
  participant W as atelet and worker
  rect rgba(128,128,128,0.08)
  Note over S,W: suspend NAME
  S->>H: hubctl suspend NAME
  H->>H: herdr machine disable NAME, kill its websocat tunnel
  H->>A: SuspendActor, path 2
  A->>W: checkpoint memory, free the worker<br/>snapshot uploaded to rustfs in the background
  end
  rect rgba(128,128,128,0.08)
  Note over S,W: resume NAME
  S->>H: hubctl resume NAME
  H->>A: ResumeActor, path 2
  A->>W: claim a worker, restore the actor's own snapshot
  H->>H: herdr machine enable NAME, open clients reconnect
  end
```

Both run in the hub, because the hub owns the herdr machine list and the order matters: the machine is disabled
before the suspend and re-enabled after the resume. `hubctl idle-watch` runs the same suspend automatically
(see [Lifecycle](#lifecycle)).

#### `delete <name>`

```mermaid
sequenceDiagram
  autonumber
  participant S as herdr-substrate.sh
  participant H as hub pod
  participant A as ate-api
  S->>A: GetActor NAME, stop if missing
  S->>H: hubctl remove NAME: herdr machine remove, kill tunnel
  S->>A: DeleteActorEgressPolicy NAME
  S->>A: DeleteActor NAME, discards its snapshot
```

#### `status`, `logs` and `debug <name>`

- `status`: `hubctl status` in the hub, so it shows the hub's view: actors over path 2 and the hub's herdr machines.
- `logs`: `kubectl logs -f` of the hub, where `hubctl idle-watch` logs its decisions.
- `debug <name>`: the actor's state and logs (path 1), the hub's logs, and `ssh -vvv` from the hub (path 3), which
  shows where along path 3 a connection fails.

#### `down` and `up`

- `down` runs the `delete` sequence for every actor, then deletes the template, access policy and atespace (path
  1) and the namespaces and RBAC (kubectl). The cluster, and substrate in it, stay.
- `up` runs `cluster`, `image`, `hub-image`, `hub`, `deploy`, then `actor` and `machine` for each name.

## Prebuilt images from GitHub

`.github/workflows/images.yml` builds both of the kit's images for `linux/amd64` and `linux/arm64`, and publishes
them to GitHub Container Registry. It runs when the kit is the root of a GitHub repository with Actions enabled.

- **`ghcr.io/<owner>/herdr-actor`** has no substrate dependency, so one build serves every cluster.
- **`ghcr.io/<owner>/herdr-hub`** is built once per substrate release. Its `kubectl-ate` has to come from the
  same release as the cluster, because substrate's API changes between releases. Each build's tags end in
  `-substrate-<release>`.

| Event | `herdr-actor` tags | `herdr-hub` tags |
|---|---|---|
| Push to `main` | `edge`, `sha-<commit>` | `edge-substrate-v0.6.0`, `sha-<commit>-substrate-v0.6.0` |
| Tag `v1.2.3` | `1.2.3`, `sha-<commit>` | `1.2.3-substrate-v0.6.0`, `sha-<commit>-substrate-v0.6.0` |
| Pull request | built, not pushed | built, not pushed |
| Run workflow (manual) | as for the branch or tag it runs on; input `claude_code_version` overrides the variable below | same; input `substrate_refs` overrides the variable below |

Each run's summary lists the digest-pinned references, ready to paste into `.env`. In a public repository, every
pushed image also gets a signed SLSA build-provenance attestation. Check one with:

```bash
gh attestation verify oci://ghcr.io/OWNER/herdr-actor:1.2.3 --owner OWNER
```

**Setting it up.**

1. Push the kit to a GitHub repository, with the kit's files at the root.
2. Optionally, set two repository variables (*Settings → Secrets and variables → Actions → Variables*):
   - `CLAUDE_CODE_VERSION` pins the Claude Code release in `herdr-actor`. Without it, each build takes the
     latest release and records it in the image's labels and the run summary.
   - `SUBSTRATE_REFS` is a comma-separated list of substrate releases or commits to build `herdr-hub` for. The
     default is `v0.6.0`.
3. After the first run, open each package (`herdr-actor`, `herdr-hub`) under your profile's or organization's
   *Packages*, and set its visibility to **public**. The images carry the repository in their labels, so
   GitHub shows them linked to it. GitHub creates new packages as private, and
   cluster nodes pull these images without credentials. atelet pulls actor images anonymously unless a kubelet
   credential provider is configured, and the manifests carry no image pull secrets.

**Using them.** Set the images in `.env`, by tag or by digest. The script resolves a tag to its digest when it
uses it, because templates must be digest-pinned. Then skip `image` and `hub-image`:

```bash
cat >> .env <<'EOF'
ACTOR_IMAGE=ghcr.io/OWNER/herdr-actor:1.2.3
HUB_IMAGE=ghcr.io/OWNER/herdr-hub:1.2.3-substrate-v0.6.0
EOF
```

Pick the `herdr-hub` build whose substrate release matches the cluster's:

- **Quick start:** substrate is checked out from `main`. Either keep building the hub with `hub-image`, or check
  out the same substrate commit you added to `SUBSTRATE_REFS` before running `cluster`.
- **Production:** the guides pin `v0.6.0`, the workflow's default. They copy the images into your own registry
  instead of pulling from GitHub; see their step 10.

## Configuration

Set in `.env` (see `.env.example`) or the environment. The quick start sets `ANTHROPIC_API_KEY` and, on Docker
Desktop, `BUILDX_BUILDER` (step 4); everything else has a working default.

| Variable | Default | Meaning |
|---|---|---|
| `ANTHROPIC_API_KEY` | — (required for `deploy`) | stored in a Secret; injected by the egress gateway |
| `SUBSTRATE_DIR` | `../substrate` | substrate checkout |
| `BUILDX_BUILDER` | your current builder | must use the `docker` driver: `desktop-linux` on Docker Desktop, `default` on Linux |
| `KIND_CLUSTER_NAME` | `kind` | |
| `ATESPACE` | `herdr-agents` | substrate atespace for the actors |
| `K8S_NAMESPACE` | `herdr-agents` | namespace of the actors' WorkerPool |
| `SECRETS_NAMESPACE` | `herdr-agents-secrets` | namespace of the API key Secret |
| `HUB_NAMESPACE` | `herdr-hub` | namespace of the hub; part of its SPIFFE ID |
| `WORKER_REPLICAS` | `2` | worker pods; fewer than actors is the point |
| `HERDR_VERSION` | `0.9.5` | must match the checksums pinned in the Dockerfiles |
| `IDLE_SECONDS` | `300` | idle time before the hub suspends an actor (applied by `hub`) |
| `POLL_SECONDS` | `30` | idle-bridge poll interval (applied by `hub`) |
| `ATE_INGRESS_ALLOWED_SPIFFE_IDS` | — | extra router clients; the hub's ID is always added |

The production guides add these. Their defaults are the quick start's.

| Variable | Default | Meaning |
|---|---|---|
| `KUBE_CONTEXT` | `kind-$KIND_CLUSTER_NAME` | kubeconfig context every command uses |
| `REGISTRY` | `localhost:5001` | where `image` and `hub-image` push; anything but localhost skips the kind-only builder and disk checks |
| `PLATFORM` | this machine's, e.g. `linux/arm64` | image platform; the cluster nodes' platform, e.g. `linux/amd64` |
| `CLAUDE_CODE_VERSION` | the Dockerfile's (`latest`) | Claude Code release baked into the actor image |
| `WORKER_IMAGE` | borrowed from the counter demo | digest-pinned `ateworker-gvisor` image for the WorkerPool |
| `WORKER_NODE_SELECTOR` | `{}` | YAML flow map selecting the workers' nodes, e.g. `{"ate.dev/sandboxClass": "gvisor"}` |
| `CREDENTIAL_PROVIDER` | `k8s.io` | the cluster's egress credential provider; any other value makes `deploy` skip the Secret and its grant |
| `CREDENTIAL_URI` | `ate-secret://k8s.io/default/$SECRETS_NAMESPACE/anthropic/api-key` | key reference written into each actor's egress policy |
| `ATE_CLIENT_SERVICE_ACCOUNT` | — (substrate: `ate-client`) | read by kubectl-ate: the ServiceAccount in `ate-system` it acts as |
| `ACTOR_IMAGE` | — (what `image` built) | prebuilt actor image, by tag or digest ([Prebuilt images](#prebuilt-images-from-github)) |
| `HUB_IMAGE` | — (what `hub-image` built) | prebuilt hub image; its substrate release must match the cluster's |

## Disk and resources (quick start)

The kind node's filesystem is Docker's disk. Postgres, the snapshot store (rustfs), Prometheus' metrics, pulled
images and your builds all land there, and the 1 GiB volume claims are not real limits. When it fills up,
postgres crash-loops ("No space left on device"), the API server goes 1/2, and everything that depends on it
fails in ways that look unrelated.

- Once the cluster exists, `check`, `cluster`, `image` and `hub-image` report free space and warn below 20 GB.
- `docker builder prune -a -f` frees the build cache, which is usually the largest consumer.
- Prometheus grows continuously. Restarting it empties its store, which loses nothing you need:
  `kubectl -n otel-system delete pod -l app=prometheus`.
- After freeing space, restart crashed pods instead of waiting out their back-off:
  `kubectl -n ate-system delete pod postgres-0` and `kubectl -n ate-system delete pod -l app=rustfs`.

## Files

| Path | Purpose |
|---|---|
| `actor/Dockerfile`, `actor/entrypoint.sh`, `actor/sshd_config`, `actor/herdr-config.toml` | the agent actor: Claude Code and a herdr server behind sshd behind websocat :80; pinned binaries; Claude onboarding pre-completed |
| `hub/Dockerfile`, `hub/entrypoint.sh`, `hub/herdr-config.toml` | the hub image; generates its SSH key and ssh config on its volume, runs the idle bridge; takes `kubectl-ate` from `hub/bin/linux-<arch>/` |
| `hub/ate-wss-proxy` | SSH ProxyCommand: mTLS WebSocket to atenet-router with the pod's SPIFFE certificate |
| `hub/hubctl` | add/remove machines, suspend/resume, idle bridge, `ate` passthrough |
| `manifests/hub.yaml.tmpl` | hub namespace (`ate.dev/api-access=true`), ServiceAccount, ClusterTrustBundle read RBAC, PVC, Deployment with projected identity, trust and token volumes |
| `manifests/hub-access-policy.yaml.tmpl` | atespace editor for the hub, nothing global |
| `manifests/workerpool.yaml.tmpl` | gVisor WorkerPool for the actors; node selector from `WORKER_NODE_SELECTOR` |
| `manifests/actor-template.yaml.tmpl` | the ActorTemplate (protojson for `kubectl ate create actor-template`) |
| `manifests/egress-policy.yaml.tmpl` | per actor: only `api.anthropic.com`, with `x-api-key` injection from `CREDENTIAL_URI` |
| `manifests/anthropic-secret.yaml.tmpl` | the real key, in its own namespace |
| `host/herdr-substrate.sh` | every command above |
| `docs/production-gke.md`, `docs/production-kubernetes.md` | production deployments on GKE and on upstream Kubernetes |
| `.github/workflows/images.yml` | builds and publishes `herdr-actor` and `herdr-hub` (per substrate release) to GHCR, multi-arch, with provenance |
| `test/` | `local-bridge-test.sh`, `hub-path-test.sh`, `fake_router.py`, `ssh_config.tmpl`, `Dockerfile.local` |
| `.state/` | created by the script: image digests, the hub's public key, rendered manifests. Per checkout; safe to delete |

## Verification status

**Quick start, on a real kind cluster** (Docker Desktop, macOS arm64, 2026-10-25):

| Check | Result |
|---|---|
| substrate install with the hub on the router allowlist | pass |
| Golden snapshot of the actor image under gVisor | pass |
| PTYs under gVisor (herdr panes, Claude Code's TUI) | pass |
| Hub pod certificate → router mTLS → actor; `machine add` | pass |
| Hub → ate-api authentication and atespace-editor authorization | pass |
| Default-deny egress (anything but `api.anthropic.com` → `ENOTFOUND`) | pass |
| Claude Code starts in the actor (with onboarding pre-completed) | pass |
| Credential injection (`verify`), suspend/resume round trip, automatic idle suspend | covered by the walkthrough, steps 12–14 |

**Without a cluster** (build environment, 2026-10-23):

| Check | How | Result |
|---|---|---|
| ActorTemplate, EgressPolicy, hub AccessPolicy | substrate's own `apivalidation` create-request validators | 0 errors |
| Hub Deployment, RBAC, PVC, projected `podCertificate`/`clusterTrustBundle`/token volumes | `kubeconform -strict`, Kubernetes 1.34 schemas | valid |
| Actor image under substrate's exact capability set | `test/local-bridge-test.sh` | 9/9 |
| The 4 added capabilities are required | same, `NEGATIVE=1` → `chroot("/run/sshd"): Operation not permitted` | confirmed |
| Hub → mTLS router → actor; SPIFFE allowlist and `ate-target-actor` enforced | `test/hub-path-test.sh` with `test/fake_router.py` | 13/13 |
| Idle bridge: idle agent → machine disabled → actor suspended; resume | same, `kubectl-ate` stubbed | pass |
| Enabled machine reconnects after a tunnel drop; a disabled one never does | real herdr TUI | 5 s vs none in 150 s |
| Scripts | `shellcheck` | clean |

**Production guides** (build environment, 2026-10-25). They have not yet run against a real GKE or upstream
cluster. What was checked offline:

| Check | How | Result |
|---|---|---|
| Upstream overlay builds on v0.6.0's manifests, alone and with `--cordon-control-plane`; changes only what it claims | `kustomize build`, diffed against the GKE base | pass |
| Both install documents use only settings v0.6.0 accepts | against v0.6.0's settings table | pass |
| RBAC, ConfigMaps, DaemonSet and the generated hub NetworkPolicy | `kubeconform -strict` | 15/15 valid |
| Every command block, both guides | `bash -n`, `zsh -n`, no zsh comment or `!` pitfalls | 68/68 |
| New script settings; defaults render exactly as before | template rendering, `shellcheck` | pass |

**Image workflow** (build environment, 2026-10-25). It has not yet run on GitHub. What was checked offline:

| Check | How | Result |
|---|---|---|
| Workflow syntax, expressions, permissions and its shell steps | `actionlint` 1.7.12 with `shellcheck` | clean |
| Every action's inputs, at the pinned commit | read from each action's `action.yml` | match |
| Plan and summary steps | run locally with sample variables | pass |
| Hub image takes `kubectl-ate` from `bin/linux-$TARGETARCH`; fails clearly when an architecture is missing | offline build on `localbase:host` | pass |
| `ACTOR_IMAGE`/`HUB_IMAGE` by tag, digest and registry port; missing images stop before touching the cluster | script run with stubs | pass |

## Tests

Both run against plain Docker, without a cluster. They need herdr 0.9.5, websocat 1.14 or newer, OpenSSH and
openssl on your machine (`brew install herdr websocat`), and use a throwaway `HOME`: your own herdr machines
and `~/.ssh` are untouched.

```bash
docker buildx build --load -t herdr-actor:dev actor/
```

```bash
NEGATIVE=1 test/local-bridge-test.sh herdr-actor:dev
```

The hub test also needs a hosts entry and the Python `websockets` library:

```bash
echo "127.0.0.1 atenet-router.ate-system.svc" | sudo tee -a /etc/hosts
```

```bash
pip3 install websockets
```

```bash
test/hub-path-test.sh herdr-actor:dev
```

`KEEP=1` keeps the hub test's work directory for inspection.

## Design notes that came from testing

- **Capabilities.** Actors get only `AUDIT_WRITE KILL NET_BIND_SERVICE` (`cmd/atelet/oci.go`). OpenSSH also needs
  `SETUID SETGID SYS_CHROOT CHOWN`; the template adds exactly those, inside the gVisor sandbox.
- **Actors run as UID 0 with only the image ENV**, so the actor image sets `HOME=/root`.
- **The actor's herdr server must lead its own session** (`setsid --wait`): saved-machine clients refuse a server
  that isn't a detached daemon.
- **No `Subsystem` line in the actor's sshd config.** Debian's main config already defines sftp, and bookworm's
  OpenSSH 9.2 treats a second definition as fatal. After changing the base image, check with
  `docker run --rm --entrypoint sshd <image> -t`.
- **Claude Code's first-run check probes `platform.claude.com`**, which the egress policy blocks. The actor image
  marks onboarding complete (`~/.claude.json`); with API-key auth only `api.anthropic.com` is needed.
- **websocat's `-H` takes several values**, so the URL must come before it.
- **One SSH host key per template**, generated during the golden-snapshot boot and shared by its actors; pinned with
  `HostKeyAlias`, forgotten by `deploy` when the template changes.
- **OpenSSH resolves `~` from the password database, not `$HOME`.** The hub's `HOME` is its volume, so the image
  points root's home there (by editing `/etc/passwd`; `usermod` refuses during a build) and `hubctl` passes `-F`.
- **Pod certificates rotate.** `ate-wss-proxy` converts the projected bundle to PKCS#12 for websocat, cached by
  content hash, so a new bundle always gets a new conversion.
- **`kubectl exec -it` starts with a 0×0 terminal** and sends the real size afterwards; herdr refuses 0×0, so
  `attach` sets the size with `stty` first.
- **A missing access or egress policy is not an error** for `kubectl ate get`: it exits 0 and prints nothing.
  The script decides by output.
- **Image digests come from the registry** when buildx's metadata lacks them (Docker Desktop's engine-side push).
- **Pushes to `localhost:5001` need a `docker`-driver builder**; a `docker-container` builder can't reach the
  host's registry. `check` catches this.
- **No wakeup probe** on the actor: websocat only answers WebSocket upgrades on :80.

## Security notes

- The real API key lives only in a Secret the credential provider reads; actors send a placeholder that the egress
  gateway replaces. All other actor egress is denied.
- The hub's SSH private key is generated on its volume and never leaves the cluster.
- Router access is limited to the hub's SPIFFE identity; ate-api access to atespace editor on one atespace.
- No agent or port forwarding in either direction (`ForwardAgent no`; the actor's sshd refuses all forwarding).
- Anyone who can `kubectl exec` into the hub controls every actor: treat the `herdr-hub` namespace as sensitive.
- Treat each actor's herdr server as untrusted; it is a remote herdr your client renders.
- The quick start keeps substrate's development defaults. `ate-client` is a global owner, so anyone with access
  to the cluster can mint its token, and the key Secret sits in an unencrypted local etcd. The production guides
  replace both, and add network and RBAC limits around the hub.

## Troubleshooting

The chain and the table below are written for the quick start. Everything from ate-api upward applies to all
flavours. Each production guide adds a table for its platform, covering Cloud SQL or your PostgreSQL, object
storage, registries and node pools.

Failures cascade from the bottom of the stack up, so check in this order and stop at the first *no*:

```mermaid
flowchart TD
  START(["Something fails"]) --> D1{"Docker disk has room?<br/>check warns below 20 GB"}
  D1 -- no --> F1["docker builder prune -a -f<br/>docker system prune<br/>raise the Docker Desktop disk limit"]
  D1 -- yes --> D2{"postgres-0 and rustfs Running?<br/>kubectl -n ate-system get pods"}
  D2 -- no --> F2["kubectl -n ate-system logs postgres-0<br/>'No space left on device' means disk:<br/>back to the first check"]
  D2 -- yes --> D3{"ate-api-server pods 2/2?"}
  D3 -- no --> F3["kubectl -n ate-system describe pod<br/>usually waiting on postgres"]
  D3 -- yes --> D4{"headless service api has endpoints?<br/>kubectl -n ate-system get endpoints api"}
  D4 -- no --> F4["restart ate-api-server pods<br/>status shows 'no children to pick from'"]
  D4 -- yes --> D5{"hub pod Running,<br/>no missing-file warnings in logs?"}
  D5 -- no --> F5["host/herdr-substrate.sh hub<br/>check the podcertificate controller"]
  D5 -- yes --> D6{"status lists actors?"}
  D6 -- PermissionDenied --> F6["re-run deploy:<br/>grants the hub's access policy"]
  D6 -- yes --> D7{"actor's herdr machine enabled?"}
  D7 -- "disabled" --> F7["expected while suspended:<br/>resume NAME"]
  D7 -- "unknown machine" --> F8["machine NAME"]
  D7 -- yes --> D8{"debug NAME:<br/>ssh -vvv from the hub works?"}
  D8 -- no --> F9["read the actor's logs in debug output:<br/>sshd, herdr server, websocat"]
  D8 -- yes --> D9{"verify NAME prints OK?"}
  D9 -- no --> F10["Secret, credential-provider policy,<br/>egress policy for the actor"]
  D9 -- yes --> OK(["Path is healthy"])
```

`host/herdr-substrate.sh debug <actor>` prints the actor's state and logs, the hub's logs, and `ssh -vvv` from
the hub.

| Symptom | Cause and fix |
|---|---|
| `postgres-0` or `rustfs` in CrashLoopBackOff; postgres log "No space left on device"; `ate-api-server` pods 1/2 | Docker's disk is full. See [Disk and resources](#disk-and-resources-quick-start) |
| `apt-get update`: "At least one invalid signature was encountered" | Docker's disk is full: `docker builder prune -a -f`, raise the disk limit |
| `check`: builder "uses the 'docker-container' driver" / push: `dial tcp … :5001: i/o timeout` | set `BUILDX_BUILDER=desktop-linux` (Linux: `default`) in `.env` |
| `missing on PATH: kubectl-ate` | `export PATH="$(go env GOPATH)/bin:$PATH"` (the script also finds it there on its own) |
| `status`: `rpc error: code = Unavailable desc = no children to pick from` | ate-api has no ready pods; usually postgres is down. `kubectl -n ate-system get pods` |
| `status`: `PermissionDenied … lacks "can_list_actors"` | the hub's access policy is missing; re-run `deploy` |
| `deploy`: "no hub SSH key" | run `hub` (the key is kept on the hub's volume; `.state` is only a local copy) |
| `herdr: cannot attach without a usable terminal: … zero-sized grid` | use `host/herdr-substrate.sh attach`, which sets the terminal size |
| `error: unknown machine '<name>'` | the `machine <name>` step hasn't completed; run it |
| `machine '<name>' is disabled` | expected while suspended; `resume <name>` |
| Claude Code: "Unable to connect to Anthropic services … platform.claude.com: ENOTFOUND" | actor built from an older image without pre-completed onboarding. In its pane: `python3 -c 'import json,os;p=os.path.expanduser("~/.claude.json");d=json.load(open(p)) if os.path.exists(p) else {};d["hasCompletedOnboarding"]=True;json.dump(d,open(p,"w"))'` |
| `verify`: "API answered with an error" | the gateway didn't inject the key: check the Secret, and that `deploy` granted the credential-provider policy |
| `remote server is not ready for saved machines` | actor image without `setsid` (old build) or herdr version mismatch between hub and actor |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | template recreated outside `deploy`; in the hub: `ssh-keygen -R herdr-substrate-herdr-agents -f ~/.ssh/known_hosts.herdr-substrate` |
| An actor resumes right after being suspended | something re-enabled its machine or resumed it; check `status` and `logs` |
| zsh: a pasted command waits at `quote>` | it contained a `#` comment with an apostrophe; press Ctrl-C. `setopt interactive_comments` in `~/.zshrc` makes zsh accept comments |

## Changelog

Fixes made while bringing the kit up on a real cluster, all included above:

- **Hub topology.** The herdr client and lifecycle controller moved from the laptop into a hub pod: the router
  admits only allowlisted SPIFFE identities, and actors can't host the client. `cluster` allowlists the hub.
- **Actor image:** no duplicate sftp `Subsystem` (fatal on Debian's OpenSSH); herdr server started with `setsid`;
  Claude Code onboarding pre-completed.
- **Hub image:** root's home set via `/etc/passwd` (not `usermod`); `ssh` called with `-F`.
- **Host script:** builder-driver check; digest fallback to the registry; `demo counter` subcommand; counter
  workers scaled to 0; `kubectl-ate` found in Go's bin directory; hub key fetched from the hub when `.state` lacks
  it; credential-provider policy read correctly; access/egress policy existence decided by output; `attach` sets
  the terminal size; disk-space warnings; new `verify` and `delete` commands.
- **Tests:** keep your Docker context when switching `HOME`; print the container log when sshd fails.
- **Production:** guides for GKE and upstream Kubernetes (`docs/`). The script gained `PLATFORM`,
  `CLAUDE_CODE_VERSION`, `WORKER_IMAGE`, `WORKER_NODE_SELECTOR`, `CREDENTIAL_PROVIDER` and `CREDENTIAL_URI`, and
  reads digests from remote registries. Defaults leave kind unchanged. The actor template no longer sets
  `snapshotConfig.storageLocation`, which substrate ignores without its `PerTemplateSnapshotLocation` preview gate.
- **Prebuilt images:** a GitHub workflow publishes `herdr-actor` and `herdr-hub` to GHCR for amd64 and arm64.
  The script takes them through `ACTOR_IMAGE` and `HUB_IMAGE`, by tag or digest. The hub image now takes
  `kubectl-ate` from `hub/bin/linux-<arch>/`, so one build can cover several platforms.
