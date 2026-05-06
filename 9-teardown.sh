#!/usr/bin/env bash
# Reverse of 1-run.sh. Safe to run repeatedly even if nothing is running.
#
# Default: stops the demo's containers + processes only. The kind cluster
# and Docker images are PRESERVED, so the next ./1-run.sh starts fast and
# things shared with other Kogito demos stay put.
#
# Usage:
#   ./9-teardown.sh                 # stop containers + cors-proxy
#   ./9-teardown.sh --wipe-data     # also delete ./data (persistence dir)
#   ./9-teardown.sh --full          # nuke kind cluster + demo Docker
#                                   # images + ./data + uninstall kind &
#                                   # kubectl (best-effort via brew)
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; RESET='\033[0m'
say()  { printf "${CYAN}▶ %s${RESET}\n" "$*"; }
ok()   { printf "${GREEN}✓ %s${RESET}\n" "$*"; }
warn() { printf "${YELLOW}! %s${RESET}\n" "$*"; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
KIND_CLUSTER_NAME="kie-sandbox-dev-cluster"

FLAGS=" $* "
WIPE_DATA=0; [[ "$FLAGS" == *" --wipe-data "* ]] && WIPE_DATA=1
FULL=0;      [[ "$FLAGS" == *" --full "*      ]] && FULL=1

# --full implies wipe-data + nuke cluster + nuke images + uninstall tools.
if (( FULL == 1 )); then WIPE_DATA=1; fi

# Demo-specific Docker images. Pruned only on --full (might be shared with
# other Kogito demos otherwise).
DEMO_IMAGES=(
  "apache/incubator-kie-kogito-management-console:10.1.0"
  "apache/incubator-kie-sandbox-webapp:10.1.0"
  "apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0"
  "apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0-svg"
  "alpine/curl:latest"
)
DEMO_IMAGE_PATTERNS=(
  "kindest/node"
  "registry.k8s.io/ingress-nginx/controller"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen"
)

say "Stopping demo services…"

# Containers (idempotent — silent if not present).
for c in kogito-mgmt-console kogito-mgmt-console-cloud kogito-task-console kogito-bpmn-editor; do
  if docker rm -f "$c" >/dev/null 2>&1; then ok "removed $c container"; fi
done

# Background CORS proxy
if pids=$(pgrep -f 'cors-proxy\.js' 2>/dev/null); then
  echo "$pids" | xargs kill 2>/dev/null && ok "stopped cors-proxy"
fi

# Free our two host ports if anything is squatting them.
for port in 8090 8480 8281; do
  if pids=$(lsof -ti:$port 2>/dev/null); then
    echo "$pids" | xargs kill 2>/dev/null
    sleep 0.3
    if remaining=$(lsof -ti:$port 2>/dev/null); then
      echo "$remaining" | xargs kill -9 2>/dev/null && ok "force-freed port $port"
    fi
  fi
done

if (( FULL == 0 )); then
  ok "Teardown complete (kind cluster + Docker images preserved — use --full to nuke)."
  if [[ -d "$REPO_ROOT/data" ]]; then
    ok "Preserved $REPO_ROOT/data (use --wipe-data to clear)."
  fi
  if (( WIPE_DATA == 1 )) && [[ -d "$REPO_ROOT/data" ]]; then
    rm -rf "$REPO_ROOT/data" && ok "wiped $REPO_ROOT/data"
  fi
  exit 0
fi

# --full path: aggressive cleanup -------------------------------------------

if command -v kind >/dev/null 2>&1; then
  if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    say "Deleting kind cluster '$KIND_CLUSTER_NAME'…"
    kind delete cluster --name "$KIND_CLUSTER_NAME" >/dev/null 2>&1 \
      && ok "removed kind cluster $KIND_CLUSTER_NAME" \
      || warn "kind cluster delete failed; remove manually with: kind delete cluster --name $KIND_CLUSTER_NAME"
  fi
fi

say "Pruning demo Docker images…"
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
if dangling=$(docker images -qf 'dangling=true' 2>/dev/null) && [[ -n "$dangling" ]]; then
  echo "$dangling" | xargs docker rmi -f >/dev/null 2>&1 && ok "removed dangling image layers"
fi

if [[ -d "$REPO_ROOT/data" ]]; then
  rm -rf "$REPO_ROOT/data" && ok "wiped $REPO_ROOT/data"
fi

say "Uninstalling demo-specific tools…"
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

ok "Full teardown complete."
