# Kogito BPMN — a 10-minute live demo

> **The pitch:** open a business-process diagram in VS Code, run one command,
> and you have a working REST service, a process-state dashboard, and a
> task inbox — all driven by the diagram itself. Edit the diagram, save,
> see it live. No glue code.

![Headline screenshot — Management Console showing the BPMN diagram with a live execution token](docs/screenshots/01-hero.png)

## What you'll see

- A real **BPMN 2.0 diagram** modelled in VS Code becomes an executable service.
- The **Apache KIE / jBPM** engine code-generates a REST API around the diagram at build time.
- A **Management Console** shows live process instances with the diagram highlighting where each instance is.
- A **Task Console** delivers an inbox for human approvals.
- The model encodes a real compliance pattern (the **four-eye principle** —
  two different managers must approve) and the engine enforces it.

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

`run.sh` will check all of these and explain anything missing. On Windows,
run the script from **WSL2** — the orchestration relies on a POSIX shell.

### Optional but strongly recommended: VS Code + the Apache KIE BPMN editor

The demo *runs* without an IDE, but for the headline visual of "edit the
diagram, save, see it live" you'll want a graphical BPMN editor. The
**[Apache KIE Kogito Bundle](https://marketplace.visualstudio.com/items?itemName=kie-group.vscode-extension-kogito-bundle)**
extension turns any `.bpmn` / `.bpmn2` / `.dmn` file in your editor into a
graphical canvas with a properties panel — same engine that powers
[sandbox.kie.org](https://sandbox.kie.org).

| | macOS | Linux | Windows |
|---|---|---|---|
| **VS Code** | `brew install --cask visual-studio-code` | `sudo snap install code --classic` | `winget install Microsoft.VisualStudioCode` |
| **KIE extension** | `code --install-extension kie-group.vscode-extension-kogito-bundle` (any platform — same command) | | |

Why it matters for this demo:
- Click the **First Line Approval** task in `approval.bpmn` and see the
  assignment, input/output mappings, and groups in a properties panel
  rather than reading XML.
- Rename a task graphically, save, and a re-run of `./demo.sh` reflects the
  change — no Quarkus restart, hot reload via `quarkus:dev`.
- It's the same artefact a business analyst can open at sandbox.kie.org in
  their browser without installing anything — useful for handing the BPMN
  to a non-technical reviewer.

### One command

```bash
git clone https://github.com/ch-lukas/kogito-bpmn-demo.git
cd kogito-bpmn-demo
./run.sh
```

`run.sh` will:
1. Verify prerequisites (and auto-set `JAVA_HOME` to your JDK 17 on macOS).
2. Pull / retag the required Docker images (works around an upstream tag mismatch).
3. Start the Quarkus runtime, the CORS proxy, and both consoles.
4. Print the URLs to open.

#### Running `run.sh` on each OS

| OS | How to invoke | Extra setup |
|---|---|---|
| **macOS** | `./run.sh` from a Terminal tab | None — script auto-detects JDK 17 via `/usr/libexec/java_home`. |
| **Linux** | `./run.sh` from your shell | Set `JAVA_HOME` to a JDK 17 install before running (e.g. `export JAVA_HOME=$(update-java-alternatives -l \| awk '/temurin-17/{print $3}')`). Make sure `lsof` and `pgrep` are installed (`sudo apt install lsof procps`). |
| **Windows (WSL2)** | Open **Ubuntu** (or any WSL2 distro), `cd` into the cloned repo, run `./run.sh` | Install Docker Desktop on Windows and enable its WSL2 integration. Inside WSL2, `sudo apt install lsof procps` if missing. |
| **Windows (native PowerShell / cmd)** | **Not supported.** Use WSL2. | The script relies on bash, `lsof`, `pgrep`, and POSIX nohup; native Windows shells don't have these. |

If `./run.sh` reports `permission denied`, run `chmod +x run.sh teardown.sh demo.sh` once after cloning.

You'll see something like this:

```
Demo is live. Open these in your browser:

  Management Console    http://localhost:8280  (connect with: local / http://localhost:8090)
  Task Console          http://localhost:8380
  Swagger UI            http://localhost:8080/q/swagger-ui/
  Quarkus Dev UI        http://localhost:8080/q/dev-ui/
  Data Index GraphiQL   http://localhost:8180/graphiql/
```

When you're done: `./teardown.sh`.

### Drive the process end-to-end

Run `./demo.sh` from another terminal to walk through the full lifecycle
(start a process, complete first-line approval, complete second-line as a
*different* manager, see the process disappear from the active list).

## Walkthrough

For the click-by-click presenter script — designed to be delivered live in
~10 minutes — see [DEMO.md](./DEMO.md). It covers eight scenes including
the headline visual (BPMN diagram with a live execution token), the
four-eye principle in action, and hot-reload of the model during the demo.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                       Browser tabs                           │
│  ┌─────────┐ ┌────────────┐ ┌──────────┐ ┌──────────────┐    │
│  │ VS Code │ │ Mgmt :8280 │ │ Task:8380│ │ Swagger:8080 │    │
│  └─────────┘ └─────┬──────┘ └────┬─────┘ └──────┬───────┘    │
└────────────────────┼─────────────┼──────────────┼────────────┘
                     │             │              │
                     ▼             ▼              ▼
           ┌─────────────────────────────┐   ┌───────────┐
           │ CORS proxy :8090            │   │  Direct   │
           │   /graphql → :8180          │   └─────┬─────┘
           │   *        → :8080          │         │
           └──┬──────────────────────┬───┘         │
              ▼                      ▼             ▼
      ┌──────────────┐       ┌──────────────────────────┐
      │ Data Index   │       │  Quarkus runtime :8080   │
      │  :8180       │◀──────│  (Kogito + jBPM)         │
      │  (GraphQL)   │       │   • approval.bpmn        │
      └──────────────┘       │   • Auto-generated REST  │
                             │   • Process management   │
                             └──────────────────────────┘
```

### Why the CORS proxy?

The 10.x KIE Management Console is built for OIDC-secured production runtimes.
Pointing it at an unsecured local Quarkus app trips on (a) CORS missing on the
runtime's `/` and 404 responses and (b) `Access-Control-Allow-Origin`
duplication when both the runtime and an upstream layer set headers. The proxy
([cors-proxy.js](./cors-proxy.js)) is ~80 lines of zero-dependency Node that
strips upstream CORS headers and injects a single, spec-compliant set for the
console's origin. It also routes `/graphql` to the Data Index and everything
else to the runtime.

### Custom additions on top of the upstream example

This is a fork of [`process-usertasks-quarkus`](https://github.com/apache/incubator-kie-kogito-examples/tree/10.1.x/kogito-quarkus-examples/process-usertasks-quarkus)
from Apache KIE. The additions are:

- **`pom.xml`** — three add-ons the Management Console needs (`process-management`, `process-svg`, `source-files`).
- **`src/runtime/src/main/resources/application.properties`** — CORS config, dev services switches, and `kogito.service.url` pointing at the proxy so the data-index advertises the right URL to the console.
- **`src/runtime/src/main/java/org/acme/travels/RootResource.java`** — JAX-RS endpoint at `/` so the console's auth probe gets a 200 with CORS headers.
- **`cors-proxy.js`** — the path-routed CORS injector described above.
- **`run.sh` / `teardown.sh`** — orchestration.
- **`demo.sh`** — end-to-end driver.
- **`DEMO.md`** — presenter script.

## Reference links

- Apache KIE: https://kie.apache.org
- Kogito docs (10.1.x): https://kie.apache.org/docs/10.1.x/kogito/
- Upstream example: https://github.com/apache/incubator-kie-kogito-examples/tree/10.1.x/kogito-quarkus-examples/process-usertasks-quarkus
- BPMN editor (browser-only): https://sandbox.kie.org

## Credits & license

The Quarkus project under `src/runtime/` is forked from Apache KIE and
remains under **Apache License 2.0** — see [NOTICE](./NOTICE) for the
attribution. New material in this repo (orchestration scripts, CORS proxy,
README, DEMO, etc.) is **MIT** — see [LICENSE](./LICENSE).
