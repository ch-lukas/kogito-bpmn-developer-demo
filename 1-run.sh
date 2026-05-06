#!/usr/bin/env bash
# One-command bootstrap for the analyst BPMN demo.
# Starts the CORS proxy, the local KIE Sandbox editor, the cloud
# Management Console, and a kind cluster wired up for the Sandbox's
# Dev Deployments feature.
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

# Belt-and-braces against bash job-control noise. The cors-proxy and
# any other backgrounded job is meant to live past this script, so we:
#   1. Disable monitor mode (set +m) — no "[1] Done"-style notifications
#      from this shell.
#   2. Filter "Terminated: 15" out of stderr — catches stragglers from
#      a previous-version run whose subshell still emits notifications
#      when 3-teardown.sh's pkill reaches it.
set +m
exec 2> >(grep -v 'Terminated: 15' >&2)

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

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
check_cmd node   "Install Node 18+: 'brew install node' on macOS"

if (( SKIP_DEVDEPLOY == 0 )); then
  check_cmd kind    "Install kind: 'brew install kind' on macOS, or see https://kind.sigs.k8s.io/docs/user/quick-start/. Skip Dev Deployments with: ./1-run.sh --no-devdeploy"
  check_cmd kubectl "Install kubectl: 'brew install kubectl' on macOS, or see https://kubernetes.io/docs/tasks/tools/. Skip Dev Deployments with: ./1-run.sh --no-devdeploy"
fi

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
  # Default teardown preserves expensive things (kind cluster, images).
  "$REPO_ROOT/3-teardown.sh" >/dev/null 2>&1 || true
  ok "Previous state cleared"
fi

# Pull console + editor + extended-services images up-front for
# cleaner first-run timing.
docker pull apache/incubator-kie-kogito-management-console:10.1.0      >/dev/null 2>&1 &
docker pull apache/incubator-kie-sandbox-webapp:10.1.0                 >/dev/null 2>&1 &
docker pull apache/incubator-kie-sandbox-extended-services:10.1.0      >/dev/null 2>&1 &
wait

# -----------------------------------------------------------------------------
# Start the CORS proxy as a container (was a host-side `nohup node …`,
# but bash job-control would print "Terminated: 15" on each re-run when
# the previous proxy was killed by teardown). Docker manages the
# lifecycle, no bash tracking, no notifications.
#
# Routes:
#   /bpmn/<file>      → /app/samples/<file>   (bind-mount)
#   /viewer/<id>/<p>  → in-proxy KIE read-only editor
#   /cluster/<id>/*   → host.docker.internal:80 (kind ingress on host)
# -----------------------------------------------------------------------------
say "Starting CORS proxy on :8090"
docker rm -f kogito-cors-proxy >/dev/null 2>&1 || true
docker run -d --name kogito-cors-proxy \
  -p 8090:8090 \
  --add-host=host.docker.internal:host-gateway \
  -v "$REPO_ROOT/cors-proxy.js:/app/cors-proxy.js:ro" \
  -v "$REPO_ROOT/samples:/app/samples:ro" \
  -e PORT=8090 \
  -e CLUSTER_INGRESS=http://host.docker.internal \
  -w /app \
  node:18-alpine \
  node cors-proxy.js >/dev/null
for ((i=0; i<20; i++)); do
  if curl -sf -o /dev/null "http://localhost:8090/bpmn/approval.bpmn" 2>/dev/null; then break; fi
  sleep 0.5
done
curl -sf -o /dev/null "http://localhost:8090/bpmn/approval.bpmn" \
  || die "CORS proxy not responding after 10s. Logs: docker logs kogito-cors-proxy"
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

# Single Management Console — points at the kind cluster's Sandbox
# deployments via http://localhost:8090/cluster/<deployId>. Skipped if
# Dev Deployments was opted out (no cluster to point at).
if (( SKIP_DEVDEPLOY == 0 )); then
  say "Starting Management Console on :8281"
  docker rm -f kogito-mgmt-console-cloud >/dev/null 2>&1 || true
  docker run -d --name kogito-mgmt-console-cloud -p 8281:8080 \
    apache/incubator-kie-kogito-management-console:10.1.0 >/dev/null
  wait_http "http://localhost:8281/" 90 "Management Console"
  ok "Management Console up on :8281"
fi

# Extended Services — the BPMN Editor probes localhost:21345/ping and
# uses it for the Problems tab + DMN local execution. Without it, the
# editor shows the "you need to use the Extended Services" tooltip.
say "Starting Extended Services on :21345"
docker rm -f kie-extended-services >/dev/null 2>&1 || true
docker run -d --name kie-extended-services --platform linux/amd64 -p 21345:21345 \
  -e EXTENDED_SERVICES_PORT=21345 \
  apache/incubator-kie-sandbox-extended-services:10.1.0 >/dev/null
wait_http "http://localhost:21345/ping" 90 "Extended Services"
ok "Extended Services up on :21345"

# Custom Dev Deployments base image: the upstream
# apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0
# does not include kie-addons-quarkus-process-svg, so the cloud Mgmt
# Console can't render diagrams for cluster-deployed processes. We
# layer that single dep on top in images/dev-deployment-quarkus-blank-app-svg/
# and tell the Sandbox SPA to use the patched tag.
DEVDEPLOY_IMG_BASE="apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0"
DEVDEPLOY_IMG_SVG="${DEVDEPLOY_IMG_BASE%:*}:10.1.0-svg"
DEVDEPLOY_IMG_DIR="$REPO_ROOT/images/dev-deployment-quarkus-blank-app-svg"

if (( SKIP_DEVDEPLOY == 0 )); then
  if ! docker image inspect "$DEVDEPLOY_IMG_SVG" >/dev/null 2>&1; then
    say "Building patched dev-deploy image (adds process-svg add-on) → $DEVDEPLOY_IMG_SVG"
    docker pull "$DEVDEPLOY_IMG_BASE" >/dev/null 2>&1 || true
    docker build --platform linux/amd64 -t "$DEVDEPLOY_IMG_SVG" "$DEVDEPLOY_IMG_DIR" \
      > "$LOG_DIR/dev-deploy-image-build.log" 2>&1 \
      || die "Patched dev-deploy image build failed. See $LOG_DIR/dev-deploy-image-build.log."
    ok "Patched dev-deploy image built"
  else
    ok "Patched dev-deploy image present: $DEVDEPLOY_IMG_SVG"
  fi
fi

say "Starting BPMN Editor (local sandbox.kie.org) on :8480"
docker rm -f kogito-bpmn-editor >/dev/null 2>&1 || true
if (( SKIP_DEVDEPLOY == 0 )); then
  docker run -d --name kogito-bpmn-editor --platform linux/amd64 -p 8480:8080 \
    -e KIE_SANDBOX_DEV_DEPLOYMENT_QUARKUS_BLANK_APP_IMAGE_URL="docker.io/$DEVDEPLOY_IMG_SVG" \
    apache/incubator-kie-sandbox-webapp:10.1.0 >/dev/null
else
  docker run -d --name kogito-bpmn-editor --platform linux/amd64 -p 8480:8080 \
    apache/incubator-kie-sandbox-webapp:10.1.0 >/dev/null
fi
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
  if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    say "kind cluster '$KIND_CLUSTER_NAME' already exists — reusing."
    # Cluster's own control-plane container holds ports 80/443; that's expected.

    # If Docker Desktop was restarted between runs, the control-plane node
    # container is stopped *and* its host-side API port has shifted, so
    # ~/.kube/config still points at the old port. Recover both.
    cp_container="${KIND_CLUSTER_NAME}-control-plane"
    if ! docker inspect -f '{{.State.Running}}' "$cp_container" 2>/dev/null | grep -qx true; then
      say "Starting stopped kind node ($cp_container)…"
      docker start "$cp_container" >/dev/null 2>&1 \
        || die "Could not start $cp_container. Inspect with: docker logs $cp_container"
    fi

    # Always refresh kubeconfig — the host-side API port may have shifted
    # even if the container was already running (e.g. Docker rebooted).
    kind export kubeconfig --name "$KIND_CLUSTER_NAME" >/dev/null 2>&1 \
      || warn "kind export kubeconfig failed — kubeconfig may be stale"

    # Now wait for the kube-apiserver inside the container to actually
    # answer. /healthz returns "ok" once the control plane is ready.
    say "Waiting for kube-apiserver to become healthy…"
    api_ok=false
    for ((i=0; i<60; i++)); do
      if kubectl --context "kind-$KIND_CLUSTER_NAME" get --raw=/healthz 2>/dev/null | grep -qx ok; then
        api_ok=true; break
      fi
      # Re-export occasionally in case the port wasn't yet published when we
      # first asked Docker.
      if (( i == 10 || i == 30 )); then
        kind export kubeconfig --name "$KIND_CLUSTER_NAME" >/dev/null 2>&1 || true
      fi
      sleep 1
    done
    $api_ok || die "kube-apiserver didn't answer /healthz within 60s. Try: ./3-teardown.sh && ./1-run.sh"
    ok "kube-apiserver healthy"
  else
    # Port 80 is required by the kind cluster's ingress port-mapping. Only
    # checked when we're about to *create* the cluster — if the cluster is
    # already up, port 80 is legitimately ours.
    if pids=$(lsof -ti:80 2>/dev/null) && [[ -n "$pids" ]]; then
      warn "Port 80 is in use by PID(s): $pids — Dev Deployments needs it for the kind ingress."
      warn "Free port 80 and re-run, or skip with: ./1-run.sh --no-devdeploy"
      die "Aborting Dev Deployments setup."
    fi
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
  # Use /healthz instead of `cluster-info`: works across kubectl/server skew
  # and isn't fooled by RBAC noise on the default kubernetes-admin user.
  # (For the reuse path we already waited for /healthz above; this guards
  # the freshly-created path.)
  if ! kubectl --context "kind-$KIND_CLUSTER_NAME" get --raw=/healthz 2>/dev/null | grep -qx ok; then
    die "kubectl can't reach kind context kind-$KIND_CLUSTER_NAME."
  fi

  say "Installing nginx ingress controller…"
  kubectl apply --context "kind-$KIND_CLUSTER_NAME" -f "$INGRESS_MANIFEST_URL" \
    > "$LOG_DIR/ingress-apply.log" 2>&1 || die "Ingress apply failed. See $LOG_DIR/ingress-apply.log."
  kubectl wait --context "kind-$KIND_CLUSTER_NAME" --namespace ingress-nginx \
    --for=condition=ready pod --selector=app.kubernetes.io/component=controller \
    --timeout=180s >/dev/null 2>&1 || warn "Ingress controller not ready in 180s — continuing anyway."
  ok "Ingress controller ready"

  # Make the patched dev-deploy image available inside the kind cluster so
  # the Sandbox doesn't try to pull it from a public registry (it only
  # exists locally). Idempotent — re-loading is cheap if already present.
  if docker image inspect "$DEVDEPLOY_IMG_SVG" >/dev/null 2>&1; then
    say "Loading patched dev-deploy image into kind…"
    kind load docker-image "$DEVDEPLOY_IMG_SVG" --name "$KIND_CLUSTER_NAME" \
      > "$LOG_DIR/kind-load-svg-image.log" 2>&1 \
      && ok "Patched dev-deploy image loaded into kind" \
      || warn "kind load failed; see $LOG_DIR/kind-load-svg-image.log. The cloud Mgmt Console diagram pane will be blank until this succeeds."
  fi

  say "Applying Sandbox Dev Deployments resources (proxy, RBAC, namespace)…"
  RESOURCES_YAML="$LOG_DIR/sandbox-resources.yaml"
  curl -sf "http://localhost:8480/dev-deployments/kubernetes/cluster-config/kie-sandbox-dev-deployments-resources.yaml" -o "$RESOURCES_YAML" \
    || die "Could not fetch Sandbox resources from the BPMN Editor on :8480."
  # The bundled Ingress declares pathType: Prefix with a regex path, which
  # modern nginx-ingress (>= v1.10) rejects via its validation webhook. The
  # nginx annotations on the same Ingress treat the path as a regex anyway,
  # so ImplementationSpecific is the correct pathType here.
  sed -i.bak 's/pathType: Prefix/pathType: ImplementationSpecific/g' "$RESOURCES_YAML"

  # The bundled kube-apiserver-proxy pod downloads the *latest* kubectl
  # from dl.k8s.io/release/stable.txt at start-up. Recent latest builds
  # crash with SIGSEGV in golang.org/x/net@v0.49.0 http2 transport while
  # serving requests, putting the pod in CrashLoopBackOff and breaking
  # the editor's "Deploy" wizard. Pin to a known-good version.
  KUBECTL_PIN="${KUBECTL_PIN:-v1.31.0}"
  sed -i.bak2 "s|\\\$(curl -L -s https://dl.k8s.io/release/stable.txt)|${KUBECTL_PIN}|g" "$RESOURCES_YAML"
  kubectl apply --context "kind-$KIND_CLUSTER_NAME" -f "$RESOURCES_YAML" \
    > "$LOG_DIR/sandbox-resources-apply.log" 2>&1 \
    || die "Sandbox resources apply failed. See $LOG_DIR/sandbox-resources-apply.log."

  say "Waiting for the kube-apiserver proxy pod…"
  kubectl wait --context "kind-$KIND_CLUSTER_NAME" --namespace default \
    --for=condition=ready pod --selector=app=kube-apiserver-proxy \
    --timeout=180s >/dev/null 2>&1 || warn "kube-apiserver-proxy not ready in 180s — continuing."

  # Prune any leftover Dev Deployments whose pod restarted into the
  # upload-wait state (Sandbox image is stateless; a Docker / kind
  # restart wipes their BPMN payload). Saves the user from clicking
  # 'Deploy' on something that will never wake up.
  if kubectl --context "kind-$KIND_CLUSTER_NAME" get ns "$DEVDEPLOY_NS" >/dev/null 2>&1; then
    say "Pruning stale Dev Deployments (upload-wait pods from previous sessions)…"
    "$REPO_ROOT/2-exec.sh" prune-stale 2>&1 | sed 's/^/  /'
  fi

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
  # Each value on its own line so triple-click selects the whole thing
  # cleanly when copy-pasting into the wizard.
  {
    echo "# Paste these into the BPMN Editor's 'Connect to Kubernetes' wizard."
    echo "# Editor: http://localhost:8480 → Dev Deployments → Connect to an account…"
    echo
    echo "Namespace:"
    echo "$DEVDEPLOY_NS"
    echo
    echo "Kubernetes API URL:"
    echo "$DEVDEPLOY_API_URL"
    echo
    echo "Token:"
    echo "$DEVDEPLOY_TOKEN"
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
if (( SKIP_DEVDEPLOY == 0 )); then
  printf "  ${GREEN}%-26s${RESET} %s\n" "Management Console" "http://localhost:8281"
  printf "  ${YELLOW}%-26s${RESET} %s\n" "  → After deploy run"  "./2-exec.sh console  # prints alias + URL to paste"
fi

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
    open_urls=("http://localhost:8480/")
    (( SKIP_DEVDEPLOY == 0 )) && open_urls+=("http://localhost:8281/")
    for url in "${open_urls[@]}"; do
      $opener "$url" >/dev/null 2>&1 &
    done
    wait
  else
    warn "No browser opener found (open / xdg-open / wslview). Open URLs manually."
  fi
fi

say "Drive deployments:   ./2-exec.sh  (start, list, viewer, console, …)"
say "Logs:                tail -f $LOG_DIR/cors-proxy.log"
say "Stop everything:     ./3-teardown.sh        (preserves kind cluster + images)"
say "Full cleanup:        ./3-teardown.sh --full (deletes cluster, images, tools)"
