#!/usr/bin/env bash
# End-to-end demo of the process-usertasks-quarkus 'approvals' BPMN flow.
#
# Prerequisite: in a separate terminal, with JAVA_HOME=JDK17, run:
#     mvn clean compile quarkus:dev
# and wait for "Listening on: http://0.0.0.0:8080".
#
# The 'approvals' BPMN models a four-eye approval flow:
#   start  →  firstLineApproval (user task, group: managers)
#          →  secondLineApproval (user task, group: managers; must be a
#                                 different user from the first one)
#          →  end
#
# This script starts a process, completes both approvals as different
# managers, and confirms the instance has finished.

set -euo pipefail

BASE="${BASE:-http://localhost:8080}"
USER1="${USER1:-john}"        # first-line approver
USER2="${USER2:-mary}"        # second-line approver
GROUP="${GROUP:-managers}"

hr()      { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }
say()     { printf '\033[2m  %s\033[0m\n' "$*"; }
showcmd() { printf '\033[1;33m$ %s\033[0m\n' "$*"; }
pause()   { read -r -p "  (press Enter to continue) " _; }

# 1. Health check
hr "1. Confirm runtime is up"
showcmd "curl -s $BASE/approvals"
if ! curl -fsS "$BASE/approvals" >/dev/null; then
  echo "Runtime not reachable at $BASE — is 'mvn quarkus:dev' running?" >&2
  exit 1
fi
say "Active approvals right now:"
curl -s "$BASE/approvals" | jq .
pause

# 2. Start a new approval process
hr "2. Start a new approval (POST /approvals)"
PAYLOAD=$(jq -n '{
  traveller: {
    firstName: "John", lastName: "Doe",
    email: "jon.doe@example.com", nationality: "American",
    address: {street: "main street", city: "Boston", zipCode: "10005", country: "US"}
  }
}')
say "Payload:"
echo "$PAYLOAD" | jq .
showcmd "curl -X POST -d '...' $BASE/approvals"
APPROVAL=$(curl -s -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$BASE/approvals")
echo "$APPROVAL" | jq .
APPROVAL_ID=$(echo "$APPROVAL" | jq -r .id)
say "Process instance id: $APPROVAL_ID"
pause

# 3. List user tasks waiting for the first approver
hr "3. List tasks waiting for '$USER1'"
showcmd "curl -s '$BASE/approvals/$APPROVAL_ID/tasks?user=$USER1&group=$GROUP'"
TASKS=$(curl -s "$BASE/approvals/$APPROVAL_ID/tasks?user=$USER1&group=$GROUP")
echo "$TASKS" | jq .
TASK_ID=$(echo "$TASKS" | jq -r '.[0].id')
TASK_NAME=$(echo "$TASKS" | jq -r '.[0].name' | tr ' ' '_')
say "First-line task id: $TASK_ID  (name: $TASK_NAME)"
pause

# 4. Complete first-line approval as USER1
hr "4. $USER1 approves the first-line task"
showcmd "curl -X POST -d '{\"approved\":true}' '$BASE/approvals/$APPROVAL_ID/$TASK_NAME/$TASK_ID?user=$USER1&group=$GROUP'"
curl -s -X POST -H 'Content-Type: application/json' -d '{"approved":true}' \
  "$BASE/approvals/$APPROVAL_ID/$TASK_NAME/$TASK_ID?user=$USER1&group=$GROUP" | jq .
pause

# 5. Show second-line task waiting (note: USER1 cannot self-approve)
hr "5. List tasks now waiting (should be second-line task for '$USER2')"
showcmd "curl -s '$BASE/approvals/$APPROVAL_ID/tasks?user=$USER2&group=$GROUP'"
TASKS=$(curl -s "$BASE/approvals/$APPROVAL_ID/tasks?user=$USER2&group=$GROUP")
echo "$TASKS" | jq .
TASK_ID=$(echo "$TASKS" | jq -r '.[0].id')
TASK_NAME=$(echo "$TASKS" | jq -r '.[0].name' | tr ' ' '_')
say "Second-line task id: $TASK_ID  (name: $TASK_NAME)"
pause

# 6. Complete second-line approval as USER2
hr "6. $USER2 approves the second-line task"
showcmd "curl -X POST -d '{\"approved\":true}' '$BASE/approvals/$APPROVAL_ID/$TASK_NAME/$TASK_ID?user=$USER2&group=$GROUP'"
curl -s -X POST -H 'Content-Type: application/json' -d '{"approved":true}' \
  "$BASE/approvals/$APPROVAL_ID/$TASK_NAME/$TASK_ID?user=$USER2&group=$GROUP" | jq .
pause

# 7. Verify completion
hr "7. Confirm the approval completed"
showcmd "curl -s $BASE/approvals"
REMAINING=$(curl -s "$BASE/approvals")
echo "$REMAINING" | jq .
if echo "$REMAINING" | jq -e --arg id "$APPROVAL_ID" 'any(.id == $id)' >/dev/null; then
  echo "Approval $APPROVAL_ID is still active — second approval did not drive process to end." >&2
  exit 1
fi
say "Approval $APPROVAL_ID completed and removed from active list."

hr "Done"
say "What you just demonstrated:"
say "  - BPMN process started via REST (approval.bpmn)"
say "  - Two human user tasks (firstLine + secondLine), assigned to group '$GROUP'"
say "  - 'Four-eye principle': $USER1 approved first, $USER2 approved second"
say "  - Process reached end event; instance disposed"
