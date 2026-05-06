#!/usr/bin/env bash
# Helpers for driving a BPMN process deployed via the Sandbox's
# Dev Deployments feature (running inside the kind cluster).
#
# Auto-discovers the deployment from the cluster's Ingress. The Sandbox
# mounts each deployment under a path prefix like /dev-deployment-<id>
# on the wildcard-host Ingress, so URLs look like:
#   http://localhost/dev-deployment-i17xri9863/q/swagger-ui/
#   http://localhost/dev-deployment-i17xri9863/hiring
#
# Usage:
#   ./2-exec.sh url                          # print base URL + Swagger
#   ./2-exec.sh swagger                      # open Swagger UI in browser
#   ./2-exec.sh health                       # GET /q/health/ready
#   ./2-exec.sh ls                           # list all deployments in the cluster
#   ./2-exec.sh console                      # print the alias + URL to paste
#                                            # into the cloud Mgmt Console (:8281)
#   ./2-exec.sh viewer [process-id]          # open a read-only KIE editor
#                                            # rendering the deployed BPMN
#   ./2-exec.sh list   [process-id]          # list active instances
#   ./2-exec.sh start  [process-id] [json]   # POST a new instance
#   ./2-exec.sh get    [process-id] <iid>    # GET one instance
#   ./2-exec.sh tasks  [process-id] <iid>    # list tasks waiting on humans
#   ./2-exec.sh complete [process-id] <iid> <task-name> <tid> [json]
#                                            # complete a user task
#
# Defaults:
#   process-id = "hiring"  (override per-call or via DEFAULT_PROCESS env var)
#   payload    = "{}"
# Env overrides:
#   KIND_CONTEXT     kubectl context (default: kind-kie-sandbox-dev-cluster)
#   DEPLOY_NAME      pin to a specific deployment app label
#                    (default: first one found in the namespace)
set -euo pipefail

KIND_CONTEXT="${KIND_CONTEXT:-kind-kie-sandbox-dev-cluster}"
NAMESPACE="local-kie-sandbox-dev-deployments"
DEFAULT_PROCESS="${DEFAULT_PROCESS:-hiring}"
BASE_HOST="${BASE_HOST:-http://localhost}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; RESET='\033[0m'
die()  { printf "${RED}✗ %s${RESET}\n" "$*" >&2; exit 1; }
info() { printf "${CYAN}▶ %s${RESET}\n" "$*" >&2; }

require() { command -v "$1" >/dev/null || die "$1 not found."; }

# Find the deployment's path prefix (e.g. "/dev-deployment-i17xri9863") by
# reading the Ingress that the Sandbox creates. With DEPLOY_NAME set, picks
# that exact one; otherwise the first.
discover_prefix() {
  require kubectl
  local prefix
  if [[ -n "${DEPLOY_NAME:-}" ]]; then
    prefix=$(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE" \
      get ingress --selector "app=${DEPLOY_NAME}" \
      -o jsonpath='{.items[0].spec.rules[0].http.paths[0].path}' 2>/dev/null || true)
  else
    prefix=$(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE" \
      get ingress \
      -o jsonpath='{.items[0].spec.rules[0].http.paths[0].path}' 2>/dev/null || true)
  fi
  if [[ -z "$prefix" ]]; then
    die "No Ingress with a path found in namespace $NAMESPACE on context $KIND_CONTEXT.
Run './2-exec.sh ls' to list deployments, or check 'Dev Deployments ▾' in the editor."
  fi
  printf '%s' "$prefix"
}

list_deployments() {
  require kubectl
  printf "%-40s %-12s %s\n" "DEPLOYMENT" "READY" "PATH"
  while IFS=$'\t' read -r name ready path; do
    [[ -n "$name" ]] && printf "%-40s %-12s %s\n" "$name" "$ready" "$path"
  done < <(
    kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE" \
      get deploy -o json 2>/dev/null \
    | (command -v jq >/dev/null \
        && jq -r '.items[] | "\(.metadata.name)\t\(.status.readyReplicas // 0)/\(.spec.replicas)\t"' \
        || awk 'BEGIN{RS="}"} /name/{print "" }')
  )
  echo
  kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE" \
    get ingress -o jsonpath='{range .items[*]}{.metadata.labels.app}{"\t→ "}{.spec.rules[0].http.paths[0].path}{"\n"}{end}' \
    | sed 's/^/  ingress: /'
}

call() {
  local method=$1 path=$2 body=${3:-}
  local prefix; prefix=$(discover_prefix)
  local url="${BASE_HOST}${prefix}${path}"
  info "$method $url${body:+  ($body)}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" -H 'Content-Type: application/json' -d "$body" "$url"
  else
    curl -fsS -X "$method" "$url"
  fi
}

pretty() { command -v jq >/dev/null && jq . || cat; }

cmd=${1:-}; [[ -n "$cmd" ]] || { sed -n '2,30p' "$0"; exit 1; }
shift || true

case "$cmd" in
  url)
    prefix=$(discover_prefix)
    printf 'Deployment base:  %s%s\n' "$BASE_HOST" "$prefix"
    printf 'Swagger UI:       %s%s/q/swagger-ui/\n' "$BASE_HOST" "$prefix"
    printf 'Health:           %s%s/q/health/ready\n' "$BASE_HOST" "$prefix"
    ;;

  swagger)
    prefix=$(discover_prefix)
    url="${BASE_HOST}${prefix}/q/swagger-ui/"
    info "Opening $url"
    if   command -v open     >/dev/null; then open "$url"
    elif command -v xdg-open >/dev/null; then xdg-open "$url"
    else printf '%s\n' "$url"
    fi
    ;;

  health)
    call GET /q/health/ready | pretty
    ;;

  ls)
    list_deployments
    ;;

  console)
    prefix=$(discover_prefix)
    # prefix looks like /dev-deployment-<id>; strip the leading "/dev-deployment-"
    deploy_id="${prefix#/dev-deployment-}"
    [[ -n "$deploy_id" && "$deploy_id" != "$prefix" ]] || die "Unexpected deployment path: $prefix"
    info "Open the cloud Mgmt Console:  http://localhost:8281"
    info "Click '+ Connect to a runtime…' and paste these:"
    printf '\n'
    printf '  %-8s %s\n' "Alias:"  "cloud"
    printf '  %-8s %s\n' "URL:"    "http://localhost:8090/cluster/${deploy_id}"
    printf '\n'
    info "(The /cluster/<id> path is rewritten by cors-proxy to ${prefix} on the kind ingress.)"
    ;;

  viewer)
    proc=${1:-$DEFAULT_PROCESS}
    prefix=$(discover_prefix)
    deploy_id="${prefix#/dev-deployment-}"
    [[ -n "$deploy_id" && "$deploy_id" != "$prefix" ]] || die "Unexpected deployment path: $prefix"
    url="http://localhost:8090/viewer/${deploy_id}/${proc}"
    info "Opening read-only KIE editor: $url"
    if   command -v open     >/dev/null; then open "$url"
    elif command -v xdg-open >/dev/null; then xdg-open "$url"
    else printf '%s\n' "$url"
    fi
    ;;

  list)
    proc=${1:-$DEFAULT_PROCESS}
    call GET "/${proc}" | pretty
    ;;

  start)
    proc=${1:-$DEFAULT_PROCESS}
    body=${2:-'{}'}
    call POST "/${proc}" "$body" | pretty
    ;;

  get)
    proc=${1:-$DEFAULT_PROCESS}; iid=${2:-}
    [[ -n "$iid" ]] || die "Usage: $0 get [process-id] <instance-id>"
    call GET "/${proc}/${iid}" | pretty
    ;;

  tasks)
    proc=${1:-$DEFAULT_PROCESS}; iid=${2:-}
    [[ -n "$iid" ]] || die "Usage: $0 tasks [process-id] <instance-id>"
    call GET "/${proc}/${iid}/tasks" | pretty
    ;;

  complete)
    proc=${1:-$DEFAULT_PROCESS}; iid=${2:-}; task=${3:-}; tid=${4:-}; body=${5:-'{}'}
    [[ -n "$iid" && -n "$task" && -n "$tid" ]] \
      || die "Usage: $0 complete [process-id] <instance-id> <task-name> <task-id> [payload-json]"
    call POST "/${proc}/${iid}/${task}/${tid}?phase=complete" "$body" | pretty
    ;;

  *)
    die "Unknown command: $cmd  (try: url|swagger|health|ls|console|viewer|list|start|get|tasks|complete)"
    ;;
esac
