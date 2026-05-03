#!/usr/bin/env bash
# One-command bootstrap for the Kogito BPMN live demo.
# Starts the runtime, the data-index, the CORS proxy, and both consoles.
#
# Usage:
#   ./run.sh           # start everything in the background
#   ./run.sh --check   # only run prerequisite checks
#
# Stop everything with: ./teardown.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$REPO_ROOT/src/runtime"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; RESET='\033[0m'
say()  { printf "${CYAN}▶ %s${RESET}\n" "$*"; }
ok()   { printf "${GREEN}✓ %s${RESET}\n" "$*"; }
warn() { printf "${YELLOW}! %s${RESET}\n" "$*"; }
die()  { printf "${RED}✗ %s${RESET}\n" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Prerequisite checks
# -----------------------------------------------------------------------------
check_cmd() {
  local cmd=$1 hint=$2
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found. $hint"
}

say "Checking prerequisites…"
check_cmd docker "Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
check_cmd mvn    "Install Maven: 'brew install maven' on macOS"
check_cmd node   "Install Node 18+: 'brew install node' on macOS"

# JDK 17 specifically (Kogito 10.1.x requires it)
if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
  if [[ "$(uname)" == "Darwin" ]] && command -v /usr/libexec/java_home >/dev/null; then
    if JAVA_HOME=$(/usr/libexec/java_home -v 17 2>/dev/null); then
      export JAVA_HOME
      ok "JAVA_HOME auto-set to $JAVA_HOME (JDK 17)"
    else
      die "JDK 17 not found. Install Temurin 17: 'brew install --cask temurin@17'"
    fi
  else
    die "JAVA_HOME is not set. Point it at a JDK 17 installation."
  fi
fi
JAVA_VER=$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | grep -oE '[0-9]+' | head -1)
[[ "$JAVA_VER" == "17" ]] || die "JAVA_HOME points at JDK $JAVA_VER, but Kogito 10.1.x needs JDK 17."
ok "JDK 17 ($JAVA_HOME)"
ok "Maven $(mvn -v 2>&1 | head -1 | awk '{print $3}')"
ok "Node $(node --version)"

docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start Docker Desktop and re-run."
ok "Docker daemon reachable"

if [[ "${1:-}" == "--check" ]]; then ok "Prerequisite check complete."; exit 0; fi

# -----------------------------------------------------------------------------
# Image preparation — work around a known broken Docker tag
# Kogito's dev services request `data-index-ephemeral:10.1` but Docker Hub
# only publishes `:10.1.0`. We retag locally so dev services can find it.
# -----------------------------------------------------------------------------
DI_IMG="apache/incubator-kie-kogito-data-index-ephemeral"
if ! docker image inspect "$DI_IMG:10.1" >/dev/null 2>&1; then
  say "Pulling and retagging $DI_IMG:10.1.0 → :10.1"
  docker pull "$DI_IMG:10.1.0"
  docker tag  "$DI_IMG:10.1.0" "$DI_IMG:10.1"
  ok "Tagged $DI_IMG:10.1"
else
  ok "$DI_IMG:10.1 already present"
fi

# Pull console images up-front for cleaner first-run timing
docker pull apache/incubator-kie-kogito-management-console:10.1.0 >/dev/null 2>&1 &
docker pull apache/incubator-kie-kogito-task-console:main         >/dev/null 2>&1 &
wait

# -----------------------------------------------------------------------------
# Start the Quarkus runtime in background
# -----------------------------------------------------------------------------
say "Starting Quarkus runtime (this will compile & start jBPM)…"
( cd "$RUNTIME_DIR" && nohup mvn -q clean compile quarkus:dev > "$LOG_DIR/quarkus.log" 2>&1 & )
# Wait for the server to be listening
for ((i=0; i<180; i++)); do
  if grep -q "Listening on:" "$LOG_DIR/quarkus.log" 2>/dev/null; then break; fi
  sleep 1
  if (( i % 15 == 14 )); then warn "still compiling… ($((i+1))s elapsed; tail -f $LOG_DIR/quarkus.log)"; fi
done
grep -q "Listening on:" "$LOG_DIR/quarkus.log" || die "Quarkus did not start in 3min. See $LOG_DIR/quarkus.log."
ok "Quarkus runtime up on :8080"

# -----------------------------------------------------------------------------
# Start the CORS proxy
# -----------------------------------------------------------------------------
say "Starting CORS proxy on :8090"
( cd "$REPO_ROOT" && nohup node cors-proxy.js > "$LOG_DIR/cors-proxy.log" 2>&1 & )
sleep 1
curl -sf -o /dev/null http://localhost:8090/approvals \
  || die "CORS proxy not responding. See $LOG_DIR/cors-proxy.log."
ok "CORS proxy up on :8090"

# -----------------------------------------------------------------------------
# Start the consoles
# -----------------------------------------------------------------------------
say "Starting Management Console on :8280"
docker rm -f kogito-mgmt-console >/dev/null 2>&1 || true
docker run -d --name kogito-mgmt-console -p 8280:8080 \
  apache/incubator-kie-kogito-management-console:10.1.0 >/dev/null
ok "Management Console container started"

say "Starting Task Console on :8380"
docker rm -f kogito-task-console >/dev/null 2>&1 || true
docker run -d --name kogito-task-console -p 8380:8080 \
  -e RUNTIME_TOOLS_TASK_CONSOLE_KOGITO_ENV_MODE=DEV \
  -e KOGITO_CONSOLES_KEYCLOAK_DISABLE_HEALTH_CHECK=true \
  -e RUNTIME_TOOLS_TASK_CONSOLE_DATA_INDEX_ENDPOINT=http://localhost:8090/graphql \
  apache/incubator-kie-kogito-task-console:main >/dev/null
ok "Task Console container started"

# -----------------------------------------------------------------------------
# Final URLs
# -----------------------------------------------------------------------------
echo
say "Demo is live. Open these in your browser:"
echo
printf "  ${GREEN}%-26s${RESET} %s\n" "Management Console"  "http://localhost:8280  (connect with: local / http://localhost:8090)"
printf "  ${GREEN}%-26s${RESET} %s\n" "Task Console"        "http://localhost:8380"
printf "  ${GREEN}%-26s${RESET} %s\n" "Swagger UI"          "http://localhost:8080/q/swagger-ui/"
printf "  ${GREEN}%-26s${RESET} %s\n" "Quarkus Dev UI"      "http://localhost:8080/q/dev-ui/"
printf "  ${GREEN}%-26s${RESET} %s\n" "Data Index GraphiQL" "http://localhost:8180/graphiql/"
echo
say "Walkthrough script:  ./DEMO.md"
say "End-to-end script:   ./demo.sh"
say "Logs:                tail -f $LOG_DIR/{quarkus,cors-proxy}.log"
say "Stop everything:     ./teardown.sh"
