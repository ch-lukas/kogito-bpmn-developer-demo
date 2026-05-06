# BPMN on Apache KIE / Kogito — Live Demo Script

A click-by-click walkthrough designed to be delivered live in **~10 minutes** to a
mixed audience (solution architects, process automation, workflow engineers).
Visuals carry the story.

> **Format conventions**
> 🖱  *Click / action you perform*
> 💬 *What you say out loud*
> 👀 *What the audience sees on screen*
> 💡 *Optional aside if you have time / get a question*

The story in one sentence: *the analyst draws a BPMN diagram in a browser, clicks Deploy,
and a real Quarkus REST service running the diagram lights up inside a Kubernetes cluster
— with a live dashboard showing where each running instance is parked.*

---

## Scene 0 — Pre-flight (do this BEFORE the audience joins)

### One command starts everything

```bash
./1-run.sh
```

It checks prereqs, clears any previous state, starts the CORS proxy, the
**BPMN Editor (your local sandbox.kie.org)**, the **Management Console**,
and a **kind Kubernetes cluster** wired up for the editor's Dev
Deployments feature. Auto-opens two browser tabs.

> First run is slow (~3–5 min) because of the kind cluster + ingress
> controller + the patched Quarkus base image. Subsequent runs reuse
> the cluster and start in ~30 s.

### Key URLs the analyst needs

| Tab | URL |
|---|---|
| **BPMN Editor** (local Sandbox) | **http://localhost:8480** |
| Sample BPMN to import | http://localhost:8090/bpmn/approval.bpmn |
| **Management Console** | **http://localhost:8281** (run `./5-exec.sh console` after first deploy for the connect URL) |
| Cloud-deployed app's Swagger UI | run `./5-exec.sh swagger` |

> No local Quarkus, no IDE. The BPMN Editor at :8480 is the same
> visual modeller that powers sandbox.kie.org, served entirely from
> your laptop. Every Quarkus runtime in this demo runs **inside the
> kind cluster**, deployed there by the editor itself.

### Heads-up: skip the Sandbox's "Log In" prompts

On first load the BPMN Editor may offer to **Connect to GitHub /
Bitbucket**. That's an *optional* integration for importing BPMN from
a Git repo — this demo doesn't use it. Dismiss the prompt.

The **Connect to Kubernetes / OpenShift** prompts (Dev Deployments
toolbar) DO get used in Scene 3 — `./1-run.sh` printed three values
for you to paste there. They're also saved to `logs/devdeploy-wizard.txt`.

---

## Scene 1 — "Meet the BPMN Editor"

💬  *"This is sandbox.kie.org — running entirely on my laptop. Same
visual modeller a business analyst would use in the browser, no
install, no account. Let me load up an example claims-approval
process so we have something to talk about."*

🖱  Switch to the **BPMN Editor** tab (http://localhost:8480/).

🖱  On the editor home, click **Import**. Paste:

```
http://localhost:8090/bpmn/approval.bpmn
```

🖱  Click **Import**. The graphical editor renders.

![Approval process](docs/screenshots/02-vscode.png)

👀 Audience sees a left-to-right flow:
*Start ▶ "First Line Approval" (user task) ▶ "Second Line Approval" (user task) ▶ End*

💬  *"BPMN — Business Process Model and Notation — is a visual standard.
Every shape has a precise meaning. Circle on the left is a start event.
Rounded rectangles with the little person icon are user tasks — steps
that need a human. Circle on the right is the end. Arrows are sequence
flow. That's almost the whole vocabulary you need to read this diagram.
A business analyst can read this; an engineer ships exactly the same
file to production."*

🖱  Click **First Line Approval**. Properties panel opens.

👀 Properties show: name, assignment (group: `managers`), input/output
mappings.

💡 *(if asked)* Pure BPMN 2.0 standard. The data-mapping and
assignment annotations are Kogito/jBPM extensions — a 1:1 swap to
Camunda or Flowable would need their equivalents wired in.

---

## Scene 2 — "Tweak the model as an analyst"

💬  *"Let me make a change you'd see in real life — renaming a step
to fit a new business term."*

🖱  Click **First Line Approval** → in the right-hand Properties
panel, rename it to "**Compliance Check**".

🖱  *(Optional, if you've got time)*: change the assignment group, add
documentation, drag a new task in.

💬  *"That's it. No code, no IDE, no engineer needed."*

---

## Scene 3 — "Deploy to Kubernetes from the editor"

💬  *"Now the trick: the same diagram becomes a real running REST
service. Watch."*

🖱  Top toolbar: **Dev Deployments ▾ → Connect to an account…**

🖱  Choose **Kubernetes** in the provider list.

When the wizard opens, ignore the multi-step "Configure a new local
Kubernetes cluster" instructions — `./1-run.sh` already did all of
that. Skip to **step 2 — Set connection info**, paste the three
values printed at the end of the run (also saved to
`logs/devdeploy-wizard.txt`):

- **Namespace:** `local-kie-sandbox-dev-deployments`
- **Kubernetes API URL:** `http://localhost/kube-apiserver`
- **Token:** *(printed by `./1-run.sh`)*

🖱  Click **Connect**. The editor confirms.

🖱  With your BPMN open, **Dev Deployments ▾ → Deploy**.

👀 The editor packages the BPMN into a Quarkus image, applies a
Deployment + Service + Ingress to kind, and shows a status badge:
🟡 deploying → 🟢 ready (~60–90 s on first deploy).

💬  *"Behind the scenes, the editor just generated a complete Quarkus
project around our BPMN — REST endpoints, persistence, the whole
thing — and rolled it onto a real Kubernetes cluster. No engineer
touched a pom.xml. Let me prove it's actually serving."*

### Ground truth from the terminal

```bash
./5-exec.sh ls            # lists deployments + their path prefix
./5-exec.sh url           # base URL + Swagger + health
./5-exec.sh health        # → {"status":"UP", ...}
```

🖱  Run `./5-exec.sh swagger` — the deployed app's Swagger UI opens.

👀 Endpoints generated from the BPMN: `POST /approvals`, `GET
/approvals`, `/approvals/{id}/firstLineApproval/{tid}` (or whatever
tasks are in *your* model — note how renaming a task in Scene 2 also
renames the URL).

💡 *(if asked)* It's not interpreted at runtime — Kogito compiles the
BPMN to Java at build time. Hence fast startup and native-image
friendliness. The kind pod *is* a Quarkus container, exactly the same
shape as a production deployment.

---

## Scene 4 — "Drive the process end-to-end"

🖱  In a terminal, start an instance:

```bash
./5-exec.sh start approvals '{"traveller":{"firstName":"John","lastName":"Doe","email":"j@d","nationality":"American","address":{"street":"main","city":"Boston","zipCode":"10005","country":"US"}}}'
```

(Replace `approvals` with your process ID — Scene 2's Properties panel
showed it.)

👀 Returns `{"id":"<uuid>", ...}` — that UUID is now a real running
BPMN process inside the cluster's Quarkus pod, parked on the first
user task waiting for a human.

### The Management Console

🖱  Run `./5-exec.sh console` — prints the alias and URL to paste.

🖱  Open http://localhost:8281, click **+ Connect to a runtime…**, paste:
- **Alias:** `cloud`
- **URL:** the URL `./5-exec.sh console` printed (looks like
  `http://localhost:8090/cluster/<deployId>`)

🖱  Click **Process Instances** → click the row.

👀 Detail page: three panels — **Details** (name, state, endpoint),
**Variables** (the JSON we just POSTed, live from the engine),
**Timeline** (`StartProcess` ✓, then **First Line Approval — Active**
with a person icon). And the **Diagram** pane renders the BPMN with
the active step **highlighted in red**.

💬  *"Live state. The engine is telling us exactly where this instance
is, the variables it carries, and the diagram lights up the active
step. Imagine a customer-facing dashboard rendering this same
timeline — 'your loan application is at the credit-check stage'.
That's what this is giving you for free."*

---

## Scene 5 — "Approve the task; see it advance"

In a terminal:

```bash
ID=<the-uuid-from-Scene-4>
./5-exec.sh tasks approvals $ID            # find the task ID + name
```

🖱  Complete via Swagger UI (`./5-exec.sh swagger`) — `POST
/approvals/{id}/firstLineApproval/{taskId}` with `{"approved":true}`,
`?phase=complete`.

👀 Refresh the Mgmt Console row → Variables now contains
`approved: true`; Timeline shows First Line Approval ✓ and **Second
Line Approval — Active**. The Diagram pane red-highlight has moved
to the next user task.

💬  *"Same diagram, advancing in real time. Now the 'production' part:
swap kind for OpenShift, swap the paste-token for an OAuth flow, swap
manual `5-exec.sh` calls for whatever orchestrates your real
processes. The story stays identical — the diagram is the source of
truth, the Quarkus runtime is the engine, the Mgmt Console is the
operations dashboard."*

---

## Scene 6 — "Edit, redeploy, see the change"

💬  *"Last move: an analyst edits the model, redeploys, and the new
version is live."*

🖱  Switch back to the **BPMN Editor**.

🖱  Rename another task or add a script task.

🖱  **Dev Deployments ▾ → Deploy**.

👀 A *new* deployment appears alongside the previous one (each deploy
gets its own ID).

🖱  Run `./5-exec.sh ls` — both versions visible.

🖱  Run `./5-exec.sh console` to get the connect URL for the new one,
paste into the Mgmt Console as a *separate* runtime (alias `cloud-v2`
or similar). Now you've got two versions of the process running side
by side, each with its own dashboard.

💬  *"That's the analyst loop, end-to-end in a browser: open the
model, change something, redeploy, see it live. Same artefact from
laptop to Kubernetes, no build step on my side."*

---

## Scene 7 — "What about real production?"

💬  *"Four things this demo doesn't show but are part of the same
stack:"*

1. **Persistence** — the deployed image already includes
   `kie-addons-quarkus-persistence-jdbc`. Swap embedded H2 for
   Postgres in production.
2. **Eventing** — process events to Kafka so other services can
   subscribe. One add-on dependency away.
3. **Native compilation** — `mvn package -Pnative` produces a ~50 MB
   stand-alone binary that boots in ~50 ms. Great for serverless.
4. **OpenShift** — the same Dev Deployments wizard's "OpenShift"
   provider replaces the paste-token with OAuth. Same flow,
   production-grade target. The
   [**Kogito Operator**](https://docs.kogito.kie.org/latest/html_single/#chap-kogito-deploying-on-openshift)
   wires deployments, services, routes, persistence, and Kafka for
   you via a `KogitoRuntime` custom resource.

---

## Scene 8 — Q & A anchor points

| Question | Where to take it |
|---|---|
| "Can a non-developer edit this?" | Already shown in Scene 2 — the BPMN Editor on :8480 *is* sandbox.kie.org running locally. No IDE involved. |
| "Does the deployed app have all the production add-ons?" | The patched dev-deploy image (`images/dev-deployment-quarkus-blank-app-svg/`) bakes `kogito-addons-quarkus-process-svg` on top of the upstream image (which already ships `process-management`, `data-index-jpa`, `persistence-jdbc`, `jobs`). Add more deps the same way. |
| "How does this differ from jBPM?" | Kogito IS the cloud-native evolution of jBPM. Same engine, packaged for Quarkus / Spring / native. |
| "Decision rules?" | Same toolchain edits DMN files (Decision Model and Notation) alongside BPMN. |
| "Can the process state outlive the pod?" | Yes — JDBC persistence is wired in. Configure a Postgres DataSource and the deployment image will use it. |
| "Why not Camunda?" | Honest answer: similar capabilities; Kogito has tighter Quarkus integration & native image; Camunda has a larger commercial ecosystem. Both are good. |

---

## Cleanup

🖱  Stop everything:
```bash
./9-teardown.sh
```
Default behaviour preserves the kind cluster, Docker images, and
`./data` so the next run starts in ~30 s. Variants:

| Flag | Adds to default |
|---|---|
| `--wipe-data` | Also delete `./data` |
| `--full` | Delete the kind cluster, prune demo Docker images, wipe `./data`, and brew-uninstall `kind` + `kubectl` |

---

## Cheat sheet — URLs

| Purpose | URL |
|---|---|
| BPMN Editor (local sandbox.kie.org) | http://localhost:8480 |
| Sample BPMN to import | http://localhost:8090/bpmn/approval.bpmn |
| Management Console | http://localhost:8281 |
| Read-only KIE viewer for any deployed BPMN | run `./5-exec.sh viewer` |
| Cloud-deployed app's Swagger UI | run `./5-exec.sh swagger` |
| CORS proxy (used internally by the consoles) | http://localhost:8090 |

## Cheat sheet — `./5-exec.sh` subcommands

```
url               base URL + Swagger + health for the current deployment
swagger           open the deployed Swagger UI in a browser
health            GET /q/health/ready
ls                list all deployments in the kind cluster
console           print the alias + URL to paste into the Mgmt Console
viewer            open a read-only KIE editor on the deployed BPMN
list  [proc]      list active instances
start [proc] [json]   POST a new instance
get   [proc] <iid>    inspect one instance
tasks [proc] <iid>    list user tasks waiting on humans
complete [proc] <iid> <task-name> <tid> [json]   complete a user task
```

Defaults to process-id `hiring`. Override with `DEFAULT_PROCESS=approvals
./5-exec.sh ...` per-session.

## Architecture (what's actually running)

```
┌──────────────────────────────────────────────────────────────┐
│                       Browser tabs                           │
│  ┌──────────────┐  ┌─────────────────┐                       │
│  │ BPMN Editor  │  │   Management    │                       │
│  │ (Sandbox)    │  │   Console       │                       │
│  │   :8480      │  │   :8281         │                       │
│  └──────┬───────┘  └────────┬────────┘                       │
└─────────┼───────────────────┼────────────────────────────────┘
          │                   │
          ▼                   ▼
   ┌────────────────────────────────────────────────────────┐
   │ CORS proxy :8090                                        │
   │   /bpmn/<file>      → samples/<file>                    │
   │   /viewer/<id>/<p>  → in-proxy KIE read-only editor     │
   │   /cluster/<id>/*   → kind ingress :80                  │
   └─────────────────────────┬───────────────────────────────┘
                             │
                             ▼
   ┌────────────────────────────────────────────────────────┐
   │ kind cluster (kie-sandbox-dev-cluster)                  │
   │ ┌────────────────────────────────────────────────────┐  │
   │ │ ingress-nginx :80                                   │  │
   │ │   /dev-deployment-<id>/* → Service → Quarkus pod    │  │
   │ │ ┌────────────────────────────────────────────────┐  │  │
   │ │ │ Quarkus pod  (built from BPMN at deploy time)   │  │  │
   │ │ │   - kogito-addons-quarkus-process-svg ✦         │  │  │
   │ │ │   - process-management, data-index-jpa, jobs    │  │  │
   │ │ │   - REST API auto-generated from BPMN           │  │  │
   │ │ └────────────────────────────────────────────────┘  │  │
   │ │   ✦ added on top of the upstream Sandbox base image │  │
   │ │     by images/dev-deployment-quarkus-blank-app-svg/ │  │
   │ └────────────────────────────────────────────────────┘  │
   └────────────────────────────────────────────────────────┘
```
