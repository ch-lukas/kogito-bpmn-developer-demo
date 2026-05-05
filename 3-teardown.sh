#!/usr/bin/env bash
# Reverse of 1-run.sh. Safe to run repeatedly even if nothing is running.
set -uo pipefail

GREEN='\033[0;32m'; CYAN='\033[1;36m'; RESET='\033[0m'
say() { printf "${CYAN}▶ %s${RESET}\n" "$*"; }
ok()  { printf "${GREEN}✓ %s${RESET}\n" "$*"; }

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

ok "Teardown complete."
