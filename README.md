# Kogito BPMN for Analysts — a 10-minute live demo

> **The pitch:** open http://localhost:8480 — that's a local copy of
> [sandbox.kie.org](https://sandbox.kie.org) running on your laptop, the
> visual BPMN editor where you create and edit processes. Run one command,
> and the same diagram is also a working REST service, a process-state
> dashboard, and a task inbox. Edit the diagram in the browser, hot-import,
> see it live. No IDE, no glue code.

![Headline screenshot — Management Console showing the BPMN diagram with a live execution token](docs/screenshots/01-hero.png)

[Apache KIE](https://kie.apache.org/) (incubating) is the open-source process- and decision-automation
project behind this demo. Originally developed at Red Hat as Drools and jBPM, it has powered
business-rule and workflow engines in production for two decades and now underpins commercial
platforms such as Red Hat Process Automation Manager. It stands out among
long-running workflow engines for its speed and cloud-native, container-first
architecture.

## What you'll see

- A real **BPMN 2.0 diagram** authored in your browser (a local **KIE Sandbox**, the same UI as sandbox.kie.org) becomes an executable service.
- The **Apache KIE / jBPM** engine code-generates a REST API around the diagram at build time.
- A **Management Console** shows live process instances with the diagram highlighting where each instance is.
- A **Task Console** delivers an inbox for human approvals.
- The model encodes a real compliance pattern (the **four-eye principle** —
  two different managers must approve) and the engine enforces it.
- Analysts edit the diagram in the browser, click Download, run `./4-import.sh`, and Quarkus hot-reloads — no IDE, no restart.

## Why it matters (for a non-technical audience)

Most "low-code" workflow tools force you to choose between a polished business
view and a real engineering toolchain. With the KIE / Kogito stack, the BPMN
diagram **is** the source of truth for both — your business analysts read the
same artefact your engineers ship to production. Every step in the diagram
becomes an inspectable, observable, auditable event in a real system.

## How to run

### Prerequisites

| Tool | Version | macOS | Linux (Debian / Ubuntu) | Windows |
|---|---|---|---|---|
| Docker Desktop | 24+ | `brew install --cask docker` | `sudo apt install docker.io docker-compose-plugin` | [Docker Desktop installer](https://www.docker.com/products/docker-desktop/) |
| JDK 17 | 17.x | `brew install --cask temurin@17` | `sudo apt install temurin-17-jdk` (after [adding the Adoptium repo](https://adoptium.net/installation/linux/)) | `winget install EclipseAdoptium.Temurin.17.JDK` |
| Maven | 3.9+ | `brew install maven` | `sudo apt install maven` | `winget install Apache.Maven` |
| Node | 18+ | `brew install node` | `sudo apt install nodejs npm` | `winget install OpenJS.NodeJS.LTS` |
| kind *(for Dev Deployments)* | 0.20+ | `brew install kind` | [kind quick start](https://kind.sigs.k8s.io/docs/user/quick-start/) | `winget install Kubernetes.kind` |
| kubectl *(for Dev Deployments)* | 1.28+ | `brew install kubectl` | `sudo apt install kubectl` (after [adding the k8s apt repo](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)) | `winget install Kubernetes.kubectl` |

> **kind / kubectl are only required if you want the Dev Deployments demo.** Skip them with `./1-run.sh --no-devdeploy` and you'll get the analyst loop without a local Kubernetes cluster.

> **For analysts who never touch the terminal after `./1-run.sh`** — JDK and Maven are needed *once*, so the workflow's REST endpoints can be regenerated from the BPMN diagram on startup. Everything after that happens in the browser.

### Persistence

Active process instances are stored in an embedded RocksDB at `./data/`
on the host. Process state survives Quarkus restarts and even
`./3-teardown.sh && ./1-run.sh`, so a demo audience can pick up where
the previous one left off. Wipe with `./3-teardown.sh --wipe-data`.

`1-run.sh` checks all of these and explains anything missing. On Windows,
run the script from **WSL2** — the orchestration relies on a POSIX shell.

### BPMN authoring — included, no IDE required

The visual BPMN editor — a local, self-hosted copy of
[sandbox.kie.org](https://sandbox.kie.org) — starts as part of `./1-run.sh`
and opens automatically at **http://localhost:8480**. Same UI, same engine,
same shortcuts as the public Sandbox; just running on your laptop with no
internet round-trip and no account.

To open the project's BPMN file in the editor, click **Import** on the
editor home and paste the URL printed by `1-run.sh`:
`http://localhost:8090/bpmn/approval.bpmn`. The CORS proxy serves it
straight from the workflow source tree.

To save edits back: click **Download** in the editor toolbar, then run
`./4-import.sh`. Quarkus dev mode hot-reloads on the next request — no
restart.

### Setup — one command

```bash
git clone https://github.com/ch-lukas/kogito-bpmn-developer-demo.git
cd kogito-bpmn-developer-demo
./1-run.sh
```

`1-run.sh` will:
1. Verify prerequisites (and auto-set `JAVA_HOME` to your JDK 17 on macOS).
2. Pull / retag the required Docker images (works around an upstream tag mismatch).
3. Start the Quarkus workflow, the CORS proxy, both consoles, and the local **BPMN Editor (Sandbox)**.
4. Create a `kind` Kubernetes cluster, install nginx ingress, apply the Sandbox's API proxy + RBAC, and print the wizard values for **Dev Deployments** *(unless `--no-devdeploy`)*.
5. Print the URLs and Dev Deployments wizard values.

#### Running `1-run.sh` on each OS

| OS | How to invoke | Extra setup |
|---|---|---|
| **macOS** | `./1-run.sh` from a Terminal tab | None — script auto-detects JDK 17 via `/usr/libexec/java_home`. |
| **Linux** | `./1-run.sh` from your shell | Set `JAVA_HOME` to a JDK 17 install before running (e.g. `export JAVA_HOME=$(update-java-alternatives -l \| awk '/temurin-17/{print $3}')`). Make sure `lsof` and `pgrep` are installed (`sudo apt install lsof procps`). |
| **Windows (WSL2)** | Open **Ubuntu** (or any WSL2 distro), `cd` into the cloned repo, run `./1-run.sh` | Install Docker Desktop on Windows and enable its WSL2 integration. Inside WSL2, `sudo apt install lsof procps` if missing. |
| **Windows (native PowerShell / cmd)** | **Not supported.** Use WSL2. | The script relies on bash, `lsof`, `pgrep`, and POSIX nohup; native Windows shells don't have these. |

If `./1-run.sh` reports `permission denied`, run `chmod +x 1-run.sh 2-demo.sh 3-teardown.sh 4-import.sh` once after cloning.

You'll see something like this:

```
Demo is live. Open these in your browser:

  BPMN Editor (Sandbox)  http://localhost:8480
    → Open file from URL  http://localhost:8090/bpmn/approval.bpmn
  Management Console     http://localhost:8281
    → After deploy run    ./5-exec.sh console  # prints alias + URL to paste
  Task Console           http://localhost:8380
  Swagger UI             http://localhost:8080/q/swagger-ui/
  Quarkus Dev UI         http://localhost:8080/q/dev-ui/
  Data Index GraphiQL    http://localhost:8180/graphiql/
```

When you're done: `./3-teardown.sh` — stops every service, removes the
kind cluster, and prunes the Docker images the demo pulled (~2 GB
reclaimed). Persistent process state in `./data/` and your installed
binaries (`kind`, `kubectl`, JDK, Maven, Node) are kept. Use
`./3-teardown.sh --full` to also wipe `./data` and uninstall `kind` /
`kubectl` via brew.

### Drive the process end-to-end

Run `./2-demo.sh` from another terminal to walk through the full lifecycle
(start a process, complete first-line approval, complete second-line as a
*different* manager, see the process disappear from the active list).

## Walkthrough

For the click-by-click presenter script — designed to be delivered live in
~10 minutes — see [DEMO.md](./DEMO.md). It covers eight scenes including
the headline visual (BPMN diagram with a live execution token), the
four-eye principle in action, and hot-reload of the model during the demo.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Browser tabs                                │
│  ┌──────────────┐ ┌────────────┐ ┌──────────┐ ┌──────────────┐       │
│  │ BPMN Editor  │ │ Mgmt :8280 │ │ Task:8380│ │ Swagger:8080 │       │
│  │ (Sandbox)    │ └─────┬──────┘ └────┬─────┘ └──────┬───────┘       │
│  │   :8480      │       │             │              │               │
│  └──────┬───────┘       │             │              │               │
└─────────┼───────────────┼─────────────┼──────────────┼───────────────┘
          │ imports BPMN  │             │              │
          ▼               ▼             ▼              ▼
   ┌────────────────────────────────────────┐   ┌───────────┐
   │ CORS proxy :8090                       │   │Direct REST│
   │   /bpmn/*  → workflow/.../approval.bpmn│   └─────┬─────┘
   │   /graphql → :8180                     │         │
   │   *        → :8080                     │         │
   └──┬───────────────────┬─────────────────┘         │
      ▼                   ▼                           ▼
 ┌──────────────┐    ┌──────────────────────────┐
 │ Data Index   │    │  Quarkus workflow :8080  │
 │  :8180       │◀───│  (Kogito + jBPM)         │
 │  (GraphQL)   │    │   • approval.bpmn        │
 └──────────────┘    │   • Auto-generated REST  │
                     │   • Process management   │
                     └──────────────────────────┘
```

### Why the CORS proxy?

The 10.x KIE Management Console is built for OIDC-secured production workflows.
Pointing it at an unsecured local Quarkus app trips on (a) CORS missing on the
workflow's `/` and 404 responses and (b) `Access-Control-Allow-Origin`
duplication when both the workflow and an upstream layer set headers. The proxy
([cors-proxy.js](./cors-proxy.js)) is ~80 lines of zero-dependency Node that
strips upstream CORS headers and injects a single, spec-compliant set for the
console's origin. It also routes `/graphql` to the Data Index and everything
else to the workflow.

### Custom additions on top of the upstream example

This is a fork of [`process-usertasks-quarkus`](https://github.com/apache/incubator-kie-kogito-examples/tree/10.1.x/kogito-quarkus-examples/process-usertasks-quarkus)
from Apache KIE. The additions are:

- **`workflow/pom.xml`** — three add-ons the Management Console needs (`process-management`, `process-svg`, `source-files`).
- **`workflow/src/main/resources/application.properties`** — CORS config, dev services switches, and `kogito.service.url` pointing at the proxy so the data-index advertises the right URL to the console.
- **`workflow/src/main/java/org/acme/travels/RootResource.java`** — JAX-RS endpoint at `/` so the console's auth probe gets a 200 with CORS headers.
- **`cors-proxy.js`** — the path-routed CORS injector described above, plus a `/bpmn/*` route that serves the live BPMN file to the local Sandbox editor.
- **Local KIE Sandbox container** (`apache/incubator-kie-sandbox-webapp:10.1.0` on port 8480) — visual BPMN editor, started by `1-run.sh`.
- **`1-run.sh` / `3-teardown.sh`** — orchestration.
- **`2-demo.sh`** — end-to-end driver.
- **`4-import.sh`** — copies an edited `approval.bpmn` from `~/Downloads` over the project file so Quarkus hot-reloads.
- **`DEMO.md`** — presenter script.

## Reference links

- Apache KIE: https://kie.apache.org
- Kogito docs (10.1.x): https://kie.apache.org/docs/10.1.x/kogito/
- Upstream example: https://github.com/apache/incubator-kie-kogito-examples/tree/10.1.x/kogito-quarkus-examples/process-usertasks-quarkus
- BPMN editor (browser-only): https://sandbox.kie.org

## Credits & license

The Quarkus project under `workflow/` is forked from Apache KIE and
remains under **Apache License 2.0** — see [NOTICE](./NOTICE) for the
attribution. New material in this repo (orchestration scripts, CORS proxy,
README, DEMO, etc.) is **MIT** — see [LICENSE](./LICENSE).
