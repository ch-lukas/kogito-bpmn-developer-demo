#!/usr/bin/env bash
# Reverse of run.sh. Safe to run repeatedly even if nothing is running.
set -uo pipefail

GREEN='\033[0;32m'; CYAN='\033[1;36m'; RESET='\033[0m'
say() { printf "${CYAN}▶ %s${RESET}\n" "$*"; }
ok()  { printf "${GREEN}✓ %s${RESET}\n" "$*"; }

say "Stopping demo services…"

# Console containers
for c in kogito-mgmt-console kogito-task-console; do
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

# Stale port holders just in case
for port in 8090 8080; do
  if pids=$(lsof -ti:$port 2>/dev/null); then
    echo "$pids" | xargs kill 2>/dev/null && ok "freed port $port"
  fi
done

ok "Teardown complete."
