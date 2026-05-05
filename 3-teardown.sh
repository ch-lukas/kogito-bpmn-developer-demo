#!/usr/bin/env bash
# Reverse of 1-run.sh. Safe to run repeatedly even if nothing is running.
#
# Usage:
#   ./3-teardown.sh             # stop everything; preserve persistent state
#   ./3-teardown.sh --wipe-data # also delete ./data (RocksDB persistence)
#   ./3-teardown.sh --keep-kind # leave the kind Dev Deployments cluster running
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; RESET='\033[0m'
say()  { printf "${CYAN}▶ %s${RESET}\n" "$*"; }
ok()   { printf "${GREEN}✓ %s${RESET}\n" "$*"; }
warn() { printf "${YELLOW}! %s${RESET}\n" "$*"; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
KIND_CLUSTER_NAME="kie-sandbox-dev-cluster"

FLAGS=" $* "
WIPE_DATA=0; [[ "$FLAGS" == *" --wipe-data "* ]] && WIPE_DATA=1
KEEP_KIND=0; [[ "$FLAGS" == *" --keep-kind "* ]] && KEEP_KIND=1

say "Stopping demo services…"

# Console + editor containers
for c in kogito-mgmt-console kogito-task-console kogito-bpmn-editor; do
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
    # Try graceful first, then force.
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

ok "Teardown complete."
