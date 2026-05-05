#!/usr/bin/env bash
# One-command bootstrap for the Kogito BPMN live demo.
# Starts the workflow, data-index, CORS proxy, both consoles, the local
# KIE Sandbox editor, and a kind cluster wired up for the Sandbox's Dev
# Deployments feature.
#
# Usage:
#   ./1-run.sh                  # start everything in the background
#   ./1-run.sh --check          # only run prerequisite checks
#   ./1-run.sh --no-devdeploy   # skip the kind cluster + Dev Deployments setup
#   ./1-run.sh --no-open        # don't auto-open browser tabs
#   ./1-run.sh --no-teardown    # don't clear previous state first
#
# Stop everything with: ./3-teardown.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$REPO_ROOT/workflow"
LOG_DIR="$REPO_ROOT/logs"
DATA_DIR="$REPO_ROOT/data"
mkdir -p "$LOG_DIR" "$DATA_DIR"

# Flag parsing — match anywhere in $@
FLAGS=" $* "
SKIP_DEVDEPLOY=0
[[ "$FLAGS" == *" --no-devdeploy "* ]] && SKIP_DEVDEPLOY=1

# Pinned versions / names used by Dev Deployments
KIND_CLUSTER_NAME="kie-sandbox-dev-cluster"
DEVDEPLOY_NS="local-kie-sandbox-dev-deployments"
INGRESS_MANIFEST_URL="https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml"

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

if (( SKIP_DEVDEPLOY == 0 )); then
  check_cmd kind    "Install kind: 'brew install kind' on macOS, or see https://kind.sigs.k8s.io/docs/user/quick-start/. Skip Dev Deployments with: ./1-run.sh --no-devdeploy"
  check_cmd kubectl "Install kubectl: 'brew install kubectl' on macOS, or see https://kubernetes.io/docs/tasks/tools/. Skip Dev Deployments with: ./1-run.sh --no-devdeploy"
fi

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
# Clean previous run — idempotent. 3-teardown.sh is safe to invoke when nothing
# is running (it exits cleanly with no-ops). Skip with: ./1-run.sh --no-teardown
# -----------------------------------------------------------------------------
if [[ "${1:-}" != "--no-teardown" ]]; then
  say "Clearing any previous demo state…"
  # --keep-kind: avoid the 60-90s kind cluster recreate on every run.
  # The kind cluster is idempotent; re-applying ingress/SAs below is a no-op.
  "$REPO_ROOT/3-teardown.sh" --keep-kind >/dev/null 2>&1 || true
  ok "Previous state cleared"
fi

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

# Pull console + editor images up-front for cleaner first-run timing
docker pull apache/incubator-kie-kogito-management-console:10.1.0 >/dev/null 2>&1 &
docker pull apache/incubator-kie-kogito-task-console:main         >/dev/null 2>&1 &
docker pull apache/incubator-kie-sandbox-webapp:10.1.0            >/dev/null 2>&1 &
wait

# -----------------------------------------------------------------------------
# Start the Quarkus runtime in background
# -----------------------------------------------------------------------------
say "Starting Quarkus runtime (this will compile & start jBPM)…"
( cd "$RUNTIME_DIR" && nohup mvn -q clean compile quarkus:dev > "$LOG_DIR/quarkus.log" 2>&1 & )

# Wait until the runtime really answers on port 8080. We can't trust
# 'Listening on:' in the log file because the Data Index dev-service
# container also logs that phrase (it binds to *its* container port 8080,
# mapped to host 8180), giving a false positive.
runtime_ready=false
for ((i=0; i<240; i++)); do
  # Bail early if Quarkus printed a fatal port-in-use error (means a stale
  # java is still squatting 8080 — teardown should have caught it).
  if grep -q "Port 8080 seems to be in use" "$LOG_DIR/quarkus.log" 2>/dev/null; then
    die "Quarkus reports port 8080 already in use. Run './3-teardown.sh' and retry, or 'lsof -i:8080' to find the squatter."
  fi
  if curl -sf -o /dev/null --max-time 2 http://localhost:8080/q/health/ready 2>/dev/null; then
    runtime_ready=true; break
  fi
  sleep 1
  if (( i % 20 == 19 )); then warn "still starting… ($((i+1))s elapsed; tail -f $LOG_DIR/quarkus.log)"; fi
done
$runtime_ready || die "Quarkus did not become healthy in 4min. See $LOG_DIR/quarkus.log."
ok "Quarkus runtime up on :8080"

# -----------------------------------------------------------------------------
# Start the CORS proxy
# -----------------------------------------------------------------------------
say "Starting CORS proxy on :8090"
( cd "$REPO_ROOT" && nohup node cors-proxy.js > "$LOG_DIR/cors-proxy.log" 2>&1 & )
# Retry the health probe — the proxy listener can take a moment to bind, and
# the upstream Quarkus app finishes initialising even after "Listening on:".
for ((i=0; i<20; i++)); do
  if curl -sf -o /dev/null http://localhost:8090/approvals 2>/dev/null; then break; fi
  sleep 0.5
done
curl -sf -o /dev/null http://localhost:8090/approvals \
  || die "CORS proxy not responding after 10s. See $LOG_DIR/cors-proxy.log."
ok "CORS proxy up on :8090"

# -----------------------------------------------------------------------------
# Start the consoles
# -----------------------------------------------------------------------------
wait_http() {
  local url=$1 timeout=${2:-60} label=$3
  for ((i=0; i<timeout; i++)); do
    if curl -sf -o /dev/null --max-time 2 "$url" 2>/dev/null; then return 0; fi
    sleep 1
    if (( i == 20 )); then warn "$label still warming up (typical under x86_64 emulation on M-series)…"; fi
  done
  warn "$label did not respond on $url within ${timeout}s — opening anyway."
}

say "Starting Management Console on :8280"
docker rm -f kogito-mgmt-console >/dev/null 2>&1 || true
docker run -d --name kogito-mgmt-console -p 8280:8080 \
  apache/incubator-kie-kogito-management-console:10.1.0 >/dev/null
wait_http "http://localhost:8280/" 90 "Management Console"
ok "Management Console up on :8280"

say "Starting Task Console on :8380"
docker rm -f kogito-task-console >/dev/null 2>&1 || true
docker run -d --name kogito-task-console -p 8380:8080 \
  -e RUNTIME_TOOLS_TASK_CONSOLE_KOGITO_ENV_MODE=DEV \
  -e KOGITO_CONSOLES_KEYCLOAK_DISABLE_HEALTH_CHECK=true \
  -e RUNTIME_TOOLS_TASK_CONSOLE_DATA_INDEX_ENDPOINT=http://localhost:8090/graphql \
  apache/incubator-kie-kogito-task-console:main >/dev/null
wait_http "http://localhost:8380/" 90 "Task Console"
ok "Task Console up on :8380"

say "Starting BPMN Editor (local sandbox.kie.org) on :8480"
docker rm -f kogito-bpmn-editor >/dev/null 2>&1 || true
docker run -d --name kogito-bpmn-editor --platform linux/amd64 -p 8480:8080 \
  apache/incubator-kie-sandbox-webapp:10.1.0 >/dev/null
wait_http "http://localhost:8480/" 90 "BPMN Editor"
ok "BPMN Editor up on :8480"

# -----------------------------------------------------------------------------
# Dev Deployments — kind cluster + ingress + Sandbox API proxy / SAs
# Lets the BPMN Editor's "Dev Deployments" feature deploy a process to a
# real Kubernetes target. YAML is fetched live from the editor container so
# it always matches the Sandbox version we shipped on :8480.
# Skip with: ./1-run.sh --no-devdeploy
# -----------------------------------------------------------------------------
DEVDEPLOY_INFO_FILE="$LOG_DIR/devdeploy-wizard.txt"
DEVDEPLOY_API_URL=""
DEVDEPLOY_TOKEN=""

if (( SKIP_DEVDEPLOY == 0 )); then
  # Port 80 is required by the kind cluster's ingress port-mapping.
  if pids=$(lsof -ti:80 2>/dev/null) && [[ -n "$pids" ]]; then
    warn "Port 80 is in use by PID(s): $pids — Dev Deployments needs it for the kind ingress."
    warn "Free port 80 and re-run, or skip with: ./1-run.sh --no-devdeploy"
    die "Aborting Dev Deployments setup."
  fi

  if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    say "kind cluster '$KIND_CLUSTER_NAME' already exists — reusing."
  else
    say "Creating kind cluster '$KIND_CLUSTER_NAME' (~60-90s)…"
    KIND_CFG="$LOG_DIR/kind-cluster-config.yaml"
    curl -sf "http://localhost:8480/dev-deployments/kubernetes/cluster-config/kind-cluster-config.yaml" -o "$KIND_CFG" \
      || die "Could not fetch kind config from the BPMN Editor on :8480."
    if ! kind create cluster --config "$KIND_CFG" > "$LOG_DIR/kind-create.log" 2>&1; then
      tail -20 "$LOG_DIR/kind-create.log" >&2
      die "kind cluster creation failed. See $LOG_DIR/kind-create.log."
    fi
    ok "kind cluster '$KIND_CLUSTER_NAME' up"
  fi

  # kind create cluster sets kubectl context to kind-<name> automatically.
  kubectl cluster-info --context "kind-$KIND_CLUSTER_NAME" >/dev/null \
    || die "kubectl can't reach kind context kind-$KIND_CLUSTER_NAME."

  say "Installing nginx ingress controller…"
  kubectl apply --context "kind-$KIND_CLUSTER_NAME" -f "$INGRESS_MANIFEST_URL" \
    > "$LOG_DIR/ingress-apply.log" 2>&1 || die "Ingress apply failed. See $LOG_DIR/ingress-apply.log."
  kubectl wait --context "kind-$KIND_CLUSTER_NAME" --namespace ingress-nginx \
    --for=condition=ready pod --selector=app.kubernetes.io/component=controller \
    --timeout=180s >/dev/null 2>&1 || warn "Ingress controller not ready in 180s — continuing anyway."
  ok "Ingress controller ready"

  say "Applying Sandbox Dev Deployments resources (proxy, RBAC, namespace)…"
  RESOURCES_YAML="$LOG_DIR/sandbox-resources.yaml"
  curl -sf "http://localhost:8480/dev-deployments/kubernetes/cluster-config/kie-sandbox-dev-deployments-resources.yaml" -o "$RESOURCES_YAML" \
    || die "Could not fetch Sandbox resources from the BPMN Editor on :8480."
  # The bundled Ingress declares pathType: Prefix with a regex path, which
  # modern nginx-ingress (>= v1.10) rejects via its validation webhook. The
  # nginx annotations on the same Ingress treat the path as a regex anyway,
  # so ImplementationSpecific is the correct pathType here.
  sed -i.bak 's/pathType: Prefix/pathType: ImplementationSpecific/g' "$RESOURCES_YAML"
  kubectl apply --context "kind-$KIND_CLUSTER_NAME" -f "$RESOURCES_YAML" \
    > "$LOG_DIR/sandbox-resources-apply.log" 2>&1 \
    || die "Sandbox resources apply failed. See $LOG_DIR/sandbox-resources-apply.log."

  say "Waiting for the kube-apiserver proxy pod…"
  kubectl wait --context "kind-$KIND_CLUSTER_NAME" --namespace default \
    --for=condition=ready pod --selector=app=kube-apiserver-proxy \
    --timeout=180s >/dev/null 2>&1 || warn "kube-apiserver-proxy not ready in 180s — continuing."

  # Token may take a moment to populate in the secret.
  say "Extracting Sandbox service-account token…"
  for ((i=0; i<20; i++)); do
    DEVDEPLOY_TOKEN=$(kubectl get secret kie-sandbox-secret --context "kind-$KIND_CLUSTER_NAME" \
      -n default -o jsonpath='{.data.token}' 2>/dev/null | base64 --decode 2>/dev/null || true)
    [[ -n "$DEVDEPLOY_TOKEN" ]] && break
    sleep 1
  done
  [[ -n "$DEVDEPLOY_TOKEN" ]] || warn "Could not read kie-sandbox-secret token. Try: kubectl -n default get secret kie-sandbox-secret -o jsonpath='{.data.token}' | base64 -d"

  DEVDEPLOY_API_URL="http://localhost/kube-apiserver"
  {
    echo "# Paste these into the BPMN Editor's 'Connect to Kubernetes' wizard."
    echo "# Editor: http://localhost:8480 → Dev Deployments → Connect to an account…"
    echo
    echo "Namespace:           $DEVDEPLOY_NS"
    echo "Kubernetes API URL:  $DEVDEPLOY_API_URL"
    echo "Token:               $DEVDEPLOY_TOKEN"
  } > "$DEVDEPLOY_INFO_FILE"
  ok "Dev Deployments ready (wizard values saved to $DEVDEPLOY_INFO_FILE)"
fi

# -----------------------------------------------------------------------------
# Final URLs
# -----------------------------------------------------------------------------
echo
say "Demo is live. Open these in your browser:"
echo
printf "  ${GREEN}%-26s${RESET} %s\n" "BPMN Editor (Sandbox)" "http://localhost:8480"
printf "  ${YELLOW}%-26s${RESET} %s\n" "  → Open file from URL"  "http://localhost:8090/bpmn/approval.bpmn"
printf "  ${GREEN}%-26s${RESET} %s\n" "Management Console"  "http://localhost:8280"
printf "  ${YELLOW}%-26s${RESET} %s\n" "  → Connect with"     "alias=local   URL=http://localhost:8090"
printf "  ${GREEN}%-26s${RESET} %s\n" "Task Console"        "http://localhost:8380"
printf "  ${GREEN}%-26s${RESET} %s\n" "Swagger UI"          "http://localhost:8080/q/swagger-ui/"
printf "  ${GREEN}%-26s${RESET} %s\n" "Quarkus Dev UI"      "http://localhost:8080/q/dev-ui/"
printf "  ${GREEN}%-26s${RESET} %s\n" "Data Index GraphiQL" "http://localhost:8180/graphiql/"

if (( SKIP_DEVDEPLOY == 0 )) && [[ -n "$DEVDEPLOY_TOKEN" ]]; then
  echo
  printf "${CYAN}▶ Dev Deployments — paste these into the editor's wizard:${RESET}\n"
  printf "  ${GREEN}%-22s${RESET} %s\n" "Namespace"          "$DEVDEPLOY_NS"
  printf "  ${GREEN}%-22s${RESET} %s\n" "Kubernetes API URL" "$DEVDEPLOY_API_URL"
  printf "  ${GREEN}%-22s${RESET} %s\n" "Token"              "${DEVDEPLOY_TOKEN:0:20}…  (full token: $DEVDEPLOY_INFO_FILE)"
  printf "  ${YELLOW}Editor route:${RESET}        http://localhost:8480 → Dev Deployments ▾ → Connect to an account…\n"
fi
echo

# -----------------------------------------------------------------------------
# Auto-open the headline tabs in the default browser. Cross-platform: macOS
# uses 'open', most Linux uses 'xdg-open', WSL2 uses 'wslview' (or
# cmd.exe). Skip with: ./1-run.sh --no-open
# -----------------------------------------------------------------------------
if [[ " $* " != *" --no-open "* ]]; then
  if command -v open >/dev/null 2>&1;            then opener="open"
  elif command -v xdg-open >/dev/null 2>&1;      then opener="xdg-open"
  elif command -v wslview >/dev/null 2>&1;       then opener="wslview"
  elif command -v cmd.exe >/dev/null 2>&1;       then opener="cmd.exe /c start"
  else opener=""
  fi
  if [[ -n "$opener" ]]; then
    say "Opening browser tabs…"
    for url in \
      "http://localhost:8480/" \
      "http://localhost:8280/" \
      "http://localhost:8080/q/swagger-ui/" \
      "http://localhost:8080/q/dev-ui/"; do
      $opener "$url" >/dev/null 2>&1 &
    done
    wait
  else
    warn "No browser opener found (open / xdg-open / wslview). Open URLs manually."
  fi
fi

say "Walkthrough script:  ./DEMO.md"
say "End-to-end script:   ./2-demo.sh"
say "Logs:                tail -f $LOG_DIR/{quarkus,cors-proxy}.log"
say "Stop everything:     ./3-teardown.sh"
