#!/usr/bin/env bash
# Print the full audit trail for a process instance: timing, variables,
# every node visited, every user task with who-did-what.
#
# Usage:  ./history.sh <process-instance-id>
#
# Requires the cors-proxy to be running (it routes /graphql to the
# data-index). If you started the demo via ./1-run.sh, you're set.

set -euo pipefail

ID=${1:?"Process instance id required.  Usage: $0 <process-instance-id>"}
PROXY=${PROXY:-http://localhost:8090}

QUERY=$(jq -n --arg id "$ID" '{
  query: "{
    ProcessInstances(where: {id: {equal: \"\($id)\"}}) {
      id processId state businessKey
      start end lastUpdate
      variables
      error { nodeDefinitionId message }
      nodes { name type enter exit }
    }
    UserTaskInstances(where: {processInstanceId: {equal: \"\($id)\"}}) {
      id name state priority
      actualOwner potentialUsers potentialGroups excludedUsers
      started completed lastUpdate
      inputs outputs
      comments    { content updatedBy updatedAt }
      attachments { name updatedBy updatedAt }
    }
  }"
}')

curl -sf -X POST -H 'Content-Type: application/json' -d "$QUERY" \
  "$PROXY/graphql" \
  | jq '{
      process: (.data.ProcessInstances[0] // null
                | if . == null then "no process instance found"
                  else {
                    id, processId, state, businessKey,
                    start, end, lastUpdate,
                    variables,
                    error,
                    trail: [.nodes[] | {name, type, enter, exit}]
                  }
                end),
      tasks:   (.data.UserTaskInstances // []
                | map({
                    name, state,
                    owner: .actualOwner,
                    priority,
                    potentialGroups, excludedUsers,
                    started, completed,
                    inputs:  (try (.inputs  | fromjson)  catch null),
                    outputs: (try (.outputs | fromjson) catch null),
                    comments, attachments
                  }))
    }'
