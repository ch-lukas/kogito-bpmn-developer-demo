# BPMN on Apache KIE / Kogito — Live Demo Script

A click-by-click walkthrough designed to be delivered live in **~10 minutes** to a
mixed audience (target: ~70% business, ~30% technical). Visuals carry the story.

> **Format conventions**
> 🖱  *Click / action you perform*
> 💬 *What you say out loud*
> 👀 *What the audience sees on screen*
> 💡 *Optional aside if you have time / get a question*

---

## Scene 0 — Pre-flight (do this BEFORE the audience joins)

You need **four things** running and **four browser tabs** ready.

### Things running

| # | What | Command | Notes |
|---|---|---|---|
| 1 | Quarkus runtime + Data Index | `mvn clean compile quarkus:dev` from this directory | Wait for "Listening on: http://0.0.0.0:8080" |
| 2 | CORS proxy | `node cors-proxy.js` from this directory | Routes 8090 → runtime/data-index with CORS headers |
| 3 | KIE Management Console | `docker run -d --name kogito-mgmt-console -p 8280:8080 apache/incubator-kie-kogito-management-console:10.1.0` | Already running from earlier setup |
| 4 | Task Console *(optional)* | `docker run -d --name kogito-task-console -p 8380:8080 -e RUNTIME_TOOLS_TASK_CONSOLE_KOGITO_ENV_MODE=DEV -e KOGITO_CONSOLES_KEYCLOAK_DISABLE_HEALTH_CHECK=true -e RUNTIME_TOOLS_TASK_CONSOLE_DATA_INDEX_ENDPOINT=http://localhost:8090/graphql apache/incubator-kie-kogito-task-console:main` | Skip if pressed for time — Management Console covers tasks too |

Set `JAVA_HOME` first: `export JAVA_HOME=$(/usr/libexec/java_home -v 17)`.

### Browser tabs (don't open until needed — keep them fresh on screen)

1. **VS Code** with `src/main/resources/org/acme/travels/approval.bpmn` open
2. **http://localhost:8080/q/swagger-ui/** — auto-generated REST surface
3. **http://localhost:8280/** — KIE Management Console (connect with `local` / `http://localhost:8090`)
4. **http://localhost:8380/** *(optional)* — Task Console

### Sanity checks
```bash
curl -s localhost:8080/approvals      # → []
curl -s localhost:8090/orders -o /dev/null -w "proxy: %{http_code}\n"  # → 404 expected (we use /approvals here, not /orders)
curl -s localhost:8090/approvals -o /dev/null -w "proxy: %{http_code}\n"  # → 200
```

> Cold-start build can be slow — if needed, start Scene 1 while Quarkus is still booting.

---

## Scene 1 — "What is a BPMN process?" (the model in VS Code)

🖱  Switch to **VS Code**, open `approval.bpmn`. The graphical editor renders.

👀 Audience sees a left-to-right flow:
*Start ▶ "First Line Approval" (user task) ▶ "Second Line Approval" (user task) ▶ End*

💬  *"BPMN — Business Process Model and Notation — is a visual standard for
modelling business processes. Every shape has a precise meaning. The circle on
the left is a **start event**. The rounded rectangles with the little person
icon are **user tasks** — steps that need a human. This particular model
implements a real compliance pattern: the **four-eye principle**. Approvals
must be made by two different managers — the engine itself enforces this."*

🖱  Click **First Line Approval**. Properties panel opens.

👀 Properties show: name, assignment (group: `managers`), input/output mappings.

💬  *"Notice this is just a graphical representation — under the hood it's
XML. But you and a business analyst can read this together, and what you see
is what runs in production."*

💡 *(if asked)* The file is `.bpmn` — pure BPMN 2.0 standard. Same file would
run on Camunda, Flowable, jBPM, or Kogito.

---

## Scene 2 — "How does Kogito turn a diagram into a service?"

🖱  Switch to **Terminal A** (Quarkus running). Scroll up to the build banner.

👀 Audience sees Quarkus startup log — fast (~3s) boot.

💬  *"Kogito takes that BPMN file at build time and code-generates a working
REST API. We didn't write a single REST controller. Let me show you."*

🖱  Open **http://localhost:8080/q/swagger-ui/** in the browser.

👀 Audience sees endpoints: `POST /approvals`, `GET /approvals`,
`/approvals/{id}/firstLineApproval/{tid}`, `/approvals/{id}/secondLineApproval/{tid}`.

💬  *"Every endpoint here was generated from the BPMN. The user-task
endpoints are named after the tasks in the diagram. If I rename a task in VS
Code and save, this URL changes too — the diagram IS the API."*

💡 *(if asked)* It's not interpreted at runtime — Kogito compiles the BPMN
to Java at build time. Hence the fast startup and native-image friendliness.

---

## Scene 3 — "Drive the first half of the process"

🖱  Open **http://localhost:8280/** (KIE Management Console).

👀 Audience sees the console UI, navigation: Process Instances, Jobs, Tasks.

🖱  In a terminal: `./demo.sh` and press Enter to advance to step 2 (POST /approvals).

👀 The script POSTs an approval payload (a `traveller`) and prints the new instance UUID.

💬  *"That UUID is now a real running BPMN process inside the JVM. Right
now it's parked on the first-line approval, waiting for a human."*

🖱  Switch to the Management Console → click **Process Instances** in the side nav.

👀 A row appears with status `ACTIVE`.

🖱  Click the row.

👀 The BPMN diagram renders, with a **highlighted token** sitting on
"First Line Approval". This is the headline visual.

💬  *"Live state. The engine is telling us exactly where in the process
this instance is. Imagine a customer-facing dashboard showing the same view —
'your loan application is at the credit check stage'. That's what this is
giving you for free."*

---

## Scene 4 — "Approve as a manager (impersonation)"

🖱  In the Management Console side nav, click **Tasks**.

👀 Empty list — "Anonymous" doesn't see anything.

💬  *"By default I'm logged in as Anonymous, who isn't in the managers
group. Real production would use OIDC for auth. For demo purposes the
console has an Impersonate feature."*

🖱  Click the **Impersonate** dropdown (top of page or in user menu).

🖱  Set:
- **User:** `manager`
- **Groups:** `managers`
- Click **Apply**.

👀 The First Line Approval task now appears in the list.

🖱  Click it → details panel opens (Owner: `manager`, Group: `managers`, State: `Reserved`).

🖱  In the form / actions panel, click **Complete** (or whatever the transition button is).

👀 Task disappears. Back to Process Instances → click the row → token has
moved to "Second Line Approval".

💬  *"First approval done. The engine moved the token to the next step.
Now the four-eye part — let me try to approve it again as the same person…"*

---

## Scene 5 — "The four-eye principle in action"

🖱  Tasks tab. The Second Line task is visible (still impersonating `manager`).

🖱  Try to click the **Complete** button on it.

👀 (Depending on how the BPMN enforces it) the action either:
- silently does nothing
- shows an error
- the task disappears but the process won't progress

💬  *"In a real implementation, the engine would block the same user from
completing both. Let me switch users to demonstrate."*

🖱  **Impersonate** again, this time:
- **User:** `mary` (or anyone else)
- **Groups:** `managers`
- **Apply**.

🖱  Click **Tasks** — the second-line task is visible to mary.

🖱  Complete it.

👀 Process Instances → the row disappears (process completed). Filter to
**Completed** → click → diagram shows token at end event.

💬  *"That's the full lifecycle. Started by a REST call, advanced by two
different humans, completed cleanly. The compliance rule was enforced by
the model — no application code needed."*

---

## Scene 6 — "What changes when I edit the model?"

🖱  Switch to **VS Code** → `approval.bpmn`.

🖱  Click the **First Line Approval** task → in properties, change its name
to "**Compliance Check**". Save.

🖱  Run `./demo.sh` again, or POST another `/approvals` via Swagger UI.

🖱  Switch to Management Console → Process Instances → click the new row.

👀 Diagram now shows the renamed task. **No restart.** Hot reload.

💬  *"That's the developer loop: business analyst edits the model, save,
new process instances pick it up immediately. In production you'd version
the model alongside your service."*

---

## Scene 7 — "What about production?"

💬  *"Three things I'm not showing today, but they're part of this stack:"*

1. **Persistence** — RocksDB / Postgres / Infinispan plug-and-play.
2. **Eventing** — Process events to Kafka, so other services can subscribe.
3. **Native compilation** — `mvn package -Pnative` produces a ~50 MB
   stand-alone binary that boots in ~50 ms. Great for serverless.

💬  *"And the auth piece — in production the Impersonate dropdown is
replaced by Keycloak / Okta / Azure AD. The user identity flows through to
the engine and the four-eye principle becomes a real audit trail."*

---

## Scene 8 — Q & A anchor points

| Question | Where to take it |
|---|---|
| "Can a non-developer edit this?" | VS Code's BPMN editor — same file format opens at https://sandbox.kie.org for browser-only authoring. |
| "How does this differ from jBPM?" | Kogito IS the cloud-native evolution of jBPM. Same engine, packaged for Quarkus / Spring / native. |
| "Decision rules?" | Same toolchain edits DMN files (Decision Model and Notation) alongside BPMN. |
| "OpenShift?" | Kogito Operator + standard Quarkus container build. |
| "Does it scale?" | Stateless workers + external state store; events through Kafka. SonataFlow is the serverless variant. |
| "Why not Camunda?" | Honest answer: similar capabilities; Kogito is tighter Quarkus integration & native image; Camunda has a larger commercial ecosystem. Both are good. |

---

## Cleanup

🖱  Terminal A: `Ctrl+C` to stop dev mode.
🖱  Terminal B (proxy): `Ctrl+C`.
🖱  Stop the consoles: `docker rm -f kogito-mgmt-console kogito-task-console` if you started them just for the demo.
🖱  Revert the BPMN edit if you want a clean repo:
```bash
git checkout -- src/main/resources/org/acme/travels/approval.bpmn
```

---

## Cheat sheet — URLs

| Purpose | URL |
|---|---|
| KIE Management Console | http://localhost:8280 |
| Task Console (optional) | http://localhost:8380 |
| Quarkus Swagger UI | http://localhost:8080/q/swagger-ui/ |
| Quarkus Dev UI | http://localhost:8080/q/dev-ui/ |
| Data Index GraphiQL | http://localhost:8180/graphiql/ |
| CORS proxy (what you give the consoles) | http://localhost:8090 |

## Cheat sheet — fallback curl one-liners

```bash
# Start an approval
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"traveller":{"firstName":"John","lastName":"Doe","email":"jon.doe@example.com","nationality":"American","address":{"street":"main","city":"Boston","zipCode":"10005","country":"US"}}}' \
  http://localhost:8080/approvals | jq .

# List active
curl -s http://localhost:8080/approvals | jq .

# Inspect tasks via data-index (no user filter)
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"query":"{ UserTaskInstances { id name actualOwner state processId } }"}' \
  http://localhost:8090/graphql | jq .
```

## Architecture (what's actually running)

```
┌────────────────────────────────────────────────────────────┐
│                    Browser tabs                            │
│  ┌─────────┐ ┌────────────┐ ┌───────────┐ ┌────────────┐   │
│  │ VS Code │ │ Mgmt :8280 │ │ Task:8380 │ │ Swagger    │   │
│  └─────────┘ └─────┬──────┘ └─────┬─────┘ └──────┬─────┘   │
└────────────────────┼──────────────┼──────────────┼─────────┘
                     │              │              │
                     ▼              ▼              ▼
             ┌────────────────────────────┐  ┌───────────┐
             │ CORS proxy :8090           │  │ Direct to │
             │   /graphql → :8180         │  │  :8080    │
             │   *        → :8080         │  └─────┬─────┘
             └──┬───────────────────┬─────┘        │
                │                   │              │
                ▼                   ▼              ▼
         ┌──────────────┐    ┌────────────────────────┐
         │ Data Index   │    │ Quarkus runtime :8080  │
         │  :8180       │◀───│  (Kogito + jBPM)       │
         │  (GraphQL)   │    │  - approval.bpmn       │
         └──────────────┘    │  - REST + add-ons      │
                             └────────────────────────┘
```
