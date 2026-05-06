#!/usr/bin/env bash
# Reverse of 1-run.sh. Safe to run repeatedly even if nothing is running.
#
# Default behaviour reclaims as much disk and runtime state as it can
# without touching anything you'd have to reinstall — good for keeping a
# laptop tidy between demos. Persistent process state (./data) and
# installed binaries (kind, kubectl, JDK, Maven, Node) are kept.
#
# Usage:
#   ./3-teardown.sh                 # stop services; remove containers,
#                                   # kind cluster, and pulled demo images
#   ./3-teardown.sh --keep-images   # leave Docker images on disk
#   ./3-teardown.sh --keep-kind     # leave the kind cluster running
#   ./3-teardown.sh --wipe-data     # also delete ./data (RocksDB persistence)
#   ./3-teardown.sh --full          # everything above + uninstall kind &
#                                   # kubectl (best-effort via brew on macOS)
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; RESET='\033[0m'
say()  { printf "${CYAN}▶ %s${RESET}\n" "$*"; }
ok()   { printf "${GREEN}✓ %s${RESET}\n" "$*"; }
warn() { printf "${YELLOW}! %s${RESET}\n" "$*"; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
KIND_CLUSTER_NAME="kie-sandbox-dev-cluster"

FLAGS=" $* "
WIPE_DATA=0;    [[ "$FLAGS" == *" --wipe-data "*    ]] && WIPE_DATA=1
KEEP_KIND=0;    [[ "$FLAGS" == *" --keep-kind "*    ]] && KEEP_KIND=1
KEEP_IMAGES=0;  [[ "$FLAGS" == *" --keep-images "*  ]] && KEEP_IMAGES=1
FULL=0;         [[ "$FLAGS" == *" --full "*         ]] && FULL=1

# --full implies wipe-data; cannot keep what we're about to nuke.
if (( FULL == 1 )); then WIPE_DATA=1; fi

# Demo-specific Docker images. Pruned by default; kept with --keep-images.
DEMO_IMAGES=(
  "apache/incubator-kie-kogito-management-console:10.1.0"
  "apache/incubator-kie-kogito-task-console:main"
  "apache/incubator-kie-sandbox-webapp:10.1.0"
  "apache/incubator-kie-kogito-data-index-ephemeral:10.1.0"
  "apache/incubator-kie-kogito-data-index-ephemeral:10.1"
  "apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0"
  "apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0-svg"
  "testcontainers/sshd:1.2.0"
  "testcontainers/ryuk:0.8.1"
  "alpine/curl:latest"
)
# Image *patterns* to prune (match by repository, any tag).
DEMO_IMAGE_PATTERNS=(
  "kindest/node"
  "registry.k8s.io/ingress-nginx/controller"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen"
)

say "Stopping demo services…"

# Console + editor containers
for c in kogito-mgmt-console kogito-mgmt-console-cloud kogito-task-console kogito-bpmn-editor; do
  if docker rm -f "$c" >/dev/null 2>&1; then ok "removed $c container"; fi
done

# Data Index containers spun up by Quarkus dev services
for c in $(docker ps -aq --filter ancestor=apache/incubator-kie-kogito-data-index-ephemeral:10.1 2>/dev/null); do
  docker rm -f "$c" >/dev/null && ok "removed data-index container $c"
done

# Testcontainers helpers (sshd, ryuk) used by Kogito dev services
for c in $(docker ps -aq --filter "ancestor=testcontainers/sshd:1.2.0" --filter "ancestor=testcontainers/ryuk:0.8.1" 2>/dev/null); do
  docker rm -f "$c" >/dev/null 2>&1 && ok "removed testcontainers helper $c"
done

# Background Node + Maven processes
if pids=$(pgrep -f 'cors-proxy\.js' 2>/dev/null); then
  echo "$pids" | xargs kill 2>/dev/null && ok "stopped cors-proxy"
fi
if pids=$(pgrep -f 'quarkus:dev' 2>/dev/null); then
  echo "$pids" | xargs kill 2>/dev/null && ok "stopped quarkus dev mode"
fi

# Stale port holders just in case (the Quarkus mvn fork sometimes leaves an
# orphan JVM behind that doesn't match the 'quarkus:dev' grep above).
for port in 8080 8090; do
  if pids=$(lsof -ti:$port 2>/dev/null); then
    echo "$pids" | xargs kill 2>/dev/null
    sleep 0.5
    if remaining=$(lsof -ti:$port 2>/dev/null); then
      echo "$remaining" | xargs kill -9 2>/dev/null && ok "force-freed port $port"
    else
      ok "freed port $port"
    fi
  fi
done

# Dev Deployments kind cluster
if (( KEEP_KIND == 0 )) && command -v kind >/dev/null 2>&1; then
  if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    say "Deleting kind cluster '$KIND_CLUSTER_NAME'…"
    kind delete cluster --name "$KIND_CLUSTER_NAME" >/dev/null 2>&1 \
      && ok "removed kind cluster $KIND_CLUSTER_NAME" \
      || warn "kind cluster delete failed; remove manually with: kind delete cluster --name $KIND_CLUSTER_NAME"
  fi
fi

# Demo Docker images — reclaim disk
if (( KEEP_IMAGES == 0 )); then
  say "Pruning demo Docker images (use --keep-images to skip)…"
  for img in "${DEMO_IMAGES[@]}"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      docker rmi -f "$img" >/dev/null 2>&1 && ok "removed image $img"
    fi
  done
  for pat in "${DEMO_IMAGE_PATTERNS[@]}"; do
    for ref in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "^${pat}(:|$)" || true); do
      docker rmi -f "$ref" >/dev/null 2>&1 && ok "removed image $ref"
    done
  done
  # Dangling layers left behind by the prune above.
  if dangling=$(docker images -qf 'dangling=true' 2>/dev/null) && [[ -n "$dangling" ]]; then
    echo "$dangling" | xargs docker rmi -f >/dev/null 2>&1 && ok "removed dangling image layers"
  fi
fi

# Persistent state — preserved by default so future demos see prior runs.
if (( WIPE_DATA == 1 )); then
  if [[ -d "$REPO_ROOT/data" ]]; then
    rm -rf "$REPO_ROOT/data" && ok "wiped $REPO_ROOT/data (RocksDB persistence)"
  fi
else
  if [[ -d "$REPO_ROOT/data" ]]; then
    ok "preserved $REPO_ROOT/data (use --wipe-data to clear)"
  fi
fi

# --full: also uninstall the binaries the demo asked you to install.
# Best-effort. Java / Maven / Node are NOT touched — too likely to be
# shared with other projects.
if (( FULL == 1 )); then
  say "Uninstalling demo-specific tools (--full)…"
  if command -v brew >/dev/null 2>&1; then
    for pkg in kind kubectl; do
      if brew list --formula 2>/dev/null | grep -qx "$pkg"; then
        brew uninstall --quiet "$pkg" >/dev/null 2>&1 && ok "uninstalled $pkg (brew)" \
          || warn "brew uninstall $pkg failed — remove manually with: brew uninstall $pkg"
      fi
    done
  else
    warn "brew not found — uninstall kind & kubectl manually for your platform:"
    warn "  Linux (apt):  sudo apt remove kubectl && rm \$(command -v kind)"
    warn "  Windows:      winget uninstall Kubernetes.kind Kubernetes.kubectl"
  fi
fi

ok "Teardown complete."
