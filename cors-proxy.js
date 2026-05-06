#!/usr/bin/env node
// Tiny CORS-injecting reverse proxy with path-based routing. No deps.
//
// Routes (in order):
//   /viewer/<deployId>/<processId>   → in-proxy read-only KIE BPMN viewer
//   /bpmn/<file>.bpmn                → serve from samples/ (for the editor's import)
//   /cluster/<deployId>/<rest>       → kind ingress at /dev-deployment-<deployId>/<rest>
//   /dev-deployment-<deployId>/<rest> → kind ingress, path passed through unchanged
//                                       (matches the URL the runtime advertises about
//                                       itself, so the Mgmt Console's "endpoint" link works)
//
// All responses get CORS headers so the BPMN Editor (:8480) and Management
// Console (:8281) can talk to anything served here from any origin.
//
//   PORT=8090 \
//   CLUSTER_INGRESS=http://localhost \
//   node cors-proxy.js

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { URL } = require('node:url');

const PORT = Number(process.env.PORT || 8090);
// The kind cluster's nginx ingress on host:80 — Sandbox Dev Deployments
// hang off path-prefixes there (e.g. /dev-deployment-<id>).
const CLUSTER_INGRESS = new URL(process.env.CLUSTER_INGRESS || 'http://localhost');

// Sample BPMN files the editor can import directly via /bpmn/<file>.bpmn.
// Path-traversal-guarded by the regex match below.
const BPMN_DIR = path.join(__dirname, 'samples');

// HTML for the standalone read-only diagram viewer. Loads
// @kie-tools/kie-editors-standalone (the KIE-tools BPMN editor packaged
// for embedding) from unpkg, fetches the live BPMN XML through the
// /cluster/* proxy route, and opens the editor in read-only mode so
// the canvas is visible but nothing can be moved.
//
// KIE-only: kie-editors-standalone is the same editor source as the
// Sandbox webapp on :8480, just bundled as a UMD library (Apache 2.0,
// published from apache/incubator-kie-tools).
function viewerHtml({ deployId, processId }) {
  const safe = (s) => String(s).replace(/[<>&"']/g,
    (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&#39;' }[c]));
  const KIE_EDITORS_VERSION = '10.1.0';
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>BPMN — ${safe(processId)} (read-only)</title>
  <style>
    html, body { height: 100%; margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    #editor { width: 100%; height: 100vh; }
    #status {
      position: fixed; top: 8px; left: 8px; padding: 8px 12px;
      background: rgba(40,40,40,0.92); color: #fff; border-radius: 4px;
      font: 13px/1.4 ui-monospace, "SF Mono", Menlo, monospace; z-index: 10;
    }
    #status .err { color: #ff8a80; }
  </style>
</head>
<body>
  <div id="status">Loading editor bundle…</div>
  <div id="editor"></div>
  <script src="https://unpkg.com/@kie-tools/kie-editors-standalone@${KIE_EDITORS_VERSION}/dist/bpmn/index.js"></script>
  <script>
    const DEPLOY_ID  = ${JSON.stringify(deployId)};
    const PROCESS_ID = ${JSON.stringify(processId)};
    const BASE = location.origin + '/cluster/' + DEPLOY_ID;
    const status = document.getElementById('status');
    const setStatus = (msg, isError) => {
      status.innerHTML = isError ? '<span class="err">' + msg + '</span>' : msg;
    };

    (async () => {
      try {
        setStatus('Fetching BPMN XML…');
        const xmlUrl = BASE + '/management/processes/' + PROCESS_ID + '/source';
        const r = await fetch(xmlUrl);
        if (!r.ok) throw new Error(xmlUrl + ' → ' + r.status);
        const xml = await r.text();

        if (!window.bpmn || !window.bpmn.Editor) {
          throw new Error('kie-editors-standalone failed to load');
        }
        bpmn.Editor.open({
          container: document.getElementById('editor'),
          initialContent: Promise.resolve(xml),
          readOnly: true,
          origin: location.origin,
          onError: (e) => setStatus('Editor error: ' + (e && e.message || e), true),
        });
        setStatus(PROCESS_ID + ' &nbsp;<small>(read-only · KIE editor)</small>');
      } catch (err) {
        setStatus(err.message || String(err), true);
        console.error(err);
      }
    })();
  </script>
</body>
</html>`;
}

// HTML for the "Start a new process instance" form. Fetches the deployed
// runtime's OpenAPI spec, finds the request-body schema for POST /<processId>,
// and renders one input per property — typed by JSON Schema (string → text,
// integer/number → number, boolean → checkbox). Submits to the same path
// through the cors-proxy and shows the response inline. Friendlier than
// swagger-ui for non-technical users, while staying generic across processes.
function startFormHtml({ deployId, processId }) {
  const safe = (s) => String(s).replace(/[<>&"']/g,
    (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&#39;' }[c]));
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Start ${safe(processId)}</title>
  <style>
    :root { color-scheme: light dark; }
    body { font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
           max-width: 640px; margin: 2rem auto; padding: 0 1rem; }
    h1 { margin: 0 0 .25rem; }
    .sub { color: #888; font-size: 13px; margin-bottom: 1.5rem; }
    label { display: block; margin: 1rem 0 .25rem; font-weight: 600; }
    .type { color: #888; font-weight: 400; font-size: 12px; margin-left: .5rem; }
    input[type=text], input[type=number] {
      width: 100%; padding: .5rem .6rem; font: inherit; box-sizing: border-box;
      border: 1px solid #888; border-radius: 4px; background: transparent; color: inherit;
    }
    button { margin-top: 1.5rem; padding: .6rem 1.2rem; font: inherit; font-weight: 600;
             background: #0070f3; color: #fff; border: 0; border-radius: 4px; cursor: pointer; }
    button:disabled { opacity: .5; cursor: wait; }
    pre { background: rgba(127,127,127,.1); padding: 1rem; border-radius: 4px;
          overflow: auto; font-size: 13px; }
    .err { color: #d33; }
    .ok  { color: #1a7f37; }
    .links { margin-top: 1rem; font-size: 13px; }
    .links a { margin-right: 1rem; }
  </style>
</head>
<body>
  <h1>Start <em>${safe(processId)}</em></h1>
  <div class="sub">Deployment: <code>${safe(deployId)}</code></div>
  <div id="status">Loading schema…</div>
  <form id="form" hidden></form>
  <div class="links" id="links" hidden>
    <a id="swaggerLink" target="_blank">Swagger UI</a>
    <a id="mgmtLink" href="http://localhost:8281" target="_blank">Management Console</a>
  </div>
  <h3 id="resultHeading" hidden>Response</h3>
  <pre id="result" hidden></pre>
  <script>
    const DEPLOY_ID  = ${JSON.stringify(deployId)};
    const PROCESS_ID = ${JSON.stringify(processId)};
    const BASE = '/dev-deployment-' + DEPLOY_ID;
    const status = document.getElementById('status');
    const form   = document.getElementById('form');
    const result = document.getElementById('result');
    const resultHeading = document.getElementById('resultHeading');
    const links = document.getElementById('links');
    document.getElementById('swaggerLink').href = BASE + '/q/swagger-ui/#/' + PROCESS_ID;

    const setStatus = (msg, cls) => {
      status.className = cls || '';
      status.textContent = msg;
    };

    function resolveRef(spec, ref) {
      // "#/components/schemas/Foo" → spec.components.schemas.Foo
      const parts = ref.replace(/^#\\//, '').split('/');
      return parts.reduce((o, k) => (o ? o[k] : undefined), spec);
    }

    function renderInput(name, propSchema) {
      const wrap = document.createElement('div');
      const label = document.createElement('label');
      label.htmlFor = 'f_' + name;
      label.textContent = name;
      const t = document.createElement('span');
      t.className = 'type';
      t.textContent = propSchema.type + (propSchema.format ? ' (' + propSchema.format + ')' : '');
      label.appendChild(t);
      wrap.appendChild(label);

      let input;
      if (propSchema.type === 'boolean') {
        input = document.createElement('input');
        input.type = 'checkbox';
      } else if (propSchema.type === 'integer' || propSchema.type === 'number') {
        input = document.createElement('input');
        input.type = 'number';
        if (propSchema.type === 'integer') input.step = '1';
      } else {
        input = document.createElement('input');
        input.type = 'text';
      }
      input.id = 'f_' + name;
      input.name = name;
      input.dataset.type = propSchema.type || 'string';
      wrap.appendChild(input);
      return wrap;
    }

    function collectValues() {
      const obj = {};
      for (const el of form.querySelectorAll('input[name]')) {
        const t = el.dataset.type;
        if (t === 'boolean') {
          obj[el.name] = el.checked;
        } else if (t === 'integer' || t === 'number') {
          if (el.value === '') continue;
          const n = Number(el.value);
          if (!Number.isNaN(n)) obj[el.name] = n;
        } else {
          if (el.value !== '') obj[el.name] = el.value;
        }
      }
      return obj;
    }

    (async () => {
      try {
        const r = await fetch(BASE + '/q/openapi?format=json');
        if (!r.ok) throw new Error('OpenAPI fetch failed: ' + r.status);
        const spec = await r.json();
        const op = spec.paths && spec.paths[BASE + '/' + PROCESS_ID]
                 && spec.paths[BASE + '/' + PROCESS_ID].post;
        if (!op) throw new Error('No POST ' + BASE + '/' + PROCESS_ID + ' in OpenAPI spec');
        const ref = op.requestBody && op.requestBody.content
                 && op.requestBody.content['application/json']
                 && op.requestBody.content['application/json'].schema
                 && op.requestBody.content['application/json'].schema.$ref;
        if (!ref) throw new Error('No JSON request-body schema for ' + PROCESS_ID);
        const schema = resolveRef(spec, ref);
        if (!schema || !schema.properties) throw new Error('Schema has no properties');

        for (const [name, propSchema] of Object.entries(schema.properties)) {
          form.appendChild(renderInput(name, propSchema));
        }
        const submit = document.createElement('button');
        submit.type = 'submit';
        submit.textContent = 'Start ' + PROCESS_ID;
        form.appendChild(submit);

        setStatus('Fill in the fields and click "Start ' + PROCESS_ID + '".');
        form.hidden = false;
        links.hidden = false;
      } catch (err) {
        setStatus(err.message || String(err), 'err');
      }
    })();

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const submit = form.querySelector('button[type=submit]');
      submit.disabled = true;
      const body = collectValues();
      setStatus('Starting ' + PROCESS_ID + '…');
      try {
        const r = await fetch(BASE + '/' + PROCESS_ID, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        const text = await r.text();
        let pretty = text;
        try { pretty = JSON.stringify(JSON.parse(text), null, 2); } catch {}
        resultHeading.hidden = false;
        result.hidden = false;
        result.textContent = pretty;
        if (r.ok) {
          setStatus('Started — HTTP ' + r.status, 'ok');
        } else {
          setStatus('HTTP ' + r.status, 'err');
        }
      } catch (err) {
        setStatus(err.message || String(err), 'err');
      } finally {
        submit.disabled = false;
      }
    });
  </script>
</body>
</html>`;
}

function corsHeaders(req) {
  // Echo the caller's Origin (or fall back to *). Echoing is required when
  // Allow-Credentials is true — browsers reject (*) + credentials.
  const origin = req.headers.origin || '*';
  return {
    'Access-Control-Allow-Origin': origin,
    'Vary': 'Origin',
    'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS,HEAD,PATCH',
    'Access-Control-Allow-Headers':
      req.headers['access-control-request-headers'] || '*',
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Expose-Headers': '*',
  };
}

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, corsHeaders(req));
    res.end();
    return;
  }

  // /viewer/<deployId>/<processId> — read-only KIE editor canvas (no
  // Sandbox chrome) for a cluster-deployed BPMN. Live token overlay isn't
  // available because kie-editors-standalone is an editor, not a runtime
  // visualizer; the cloud Mgmt Console at :8281 does that via the
  // kie-addons-quarkus-process-svg add-on baked into the patched dev-
  // deploy image (images/dev-deployment-quarkus-blank-app-svg/).
  const viewerMatch = req.url.match(
    /^\/viewer\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)\/?$/,
  );
  if (viewerMatch) {
    const [, deployId, processId] = viewerMatch;
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      ...corsHeaders(req),
    });
    res.end(viewerHtml({ deployId, processId }));
    return;
  }

  // /start/<deployId>/<processId> — friendly form to start a new process
  // instance. Renders inputs from the deployed runtime's OpenAPI schema,
  // POSTs JSON back through the proxy. Easier than swagger-ui for non-
  // technical users; generic across processes (no per-process hardcoding).
  const startMatch = req.url.match(
    /^\/start\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)\/?$/,
  );
  if (startMatch) {
    const [, deployId, processId] = startMatch;
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      ...corsHeaders(req),
    });
    res.end(startFormHtml({ deployId, processId }));
    return;
  }

  // /bpmn/<filename>.bpmn — serve a starter BPMN from samples/ so the
  // editor at :8480 can import via URL. Path-traversal-guarded.
  const bpmnMatch = req.url.match(/^\/bpmn\/([A-Za-z0-9_-]+\.bpmn)(?:\?.*)?$/);
  if (bpmnMatch) {
    const filePath = path.join(BPMN_DIR, bpmnMatch[1]);
    fs.readFile(filePath, (err, data) => {
      if (err) {
        res.writeHead(404, { 'Content-Type': 'text/plain', ...corsHeaders(req) });
        res.end(`Not found: ${bpmnMatch[1]}`);
        return;
      }
      res.writeHead(200, {
        'Content-Type': 'application/xml; charset=utf-8',
        'Cache-Control': 'no-store',
        ...corsHeaders(req),
      });
      res.end(data);
    });
    return;
  }

  // /cluster/<deployId>/<rest> — rewrite to /dev-deployment-<deployId>/<rest>
  // and forward to the kind ingress on :80. Lets the Mgmt Console connect
  // to a Sandbox-deployed app via this proxy so CORS works the same as
  // for the BPMN Editor.
  // Two shapes hit the same upstream:
  //   /cluster/<id>/<rest>           → /dev-deployment-<id>/<rest>  (rewrite)
  //   /dev-deployment-<id>/<rest>    → /dev-deployment-<id>/<rest>  (pass-through)
  const clusterMatch = req.url.match(/^\/cluster\/([A-Za-z0-9_-]+)(\/.*)?$/);
  const passThroughMatch = !clusterMatch &&
    req.url.match(/^\/dev-deployment-([A-Za-z0-9_-]+)(\/.*)?(?:\?.*)?$/);
  // Bare endpoint URL (e.g. http://localhost:8090/dev-deployment-<id>) is what
  // the Mgmt Console links to. The deployed Quarkus app serves nothing at /,
  // so redirect to the friendly /start/<id>/<processId> form anchored on the
  // first process — Kogito exposes the list at /management/processes. Falls
  // back to swagger-ui if the lookup fails.
  if (passThroughMatch && (!passThroughMatch[2] || passThroughMatch[2] === '/')) {
    const deployId = passThroughMatch[1];
    const base = `/dev-deployment-${deployId}`;
    const lookup = http.request({
      host: CLUSTER_INGRESS.hostname,
      port: CLUSTER_INGRESS.port || 80,
      path: `${base}/management/processes`,
      method: 'GET',
      headers: { host: CLUSTER_INGRESS.host, accept: 'application/json' },
    }, (lookupRes) => {
      let body = '';
      lookupRes.on('data', (c) => { body += c; });
      lookupRes.on('end', () => {
        let target = `${base}/q/swagger-ui/`;
        try {
          const ids = JSON.parse(body);
          if (Array.isArray(ids) && ids.length > 0) {
            target = `/start/${deployId}/${encodeURIComponent(ids[0])}`;
          }
        } catch { /* fall through to bare swagger-ui */ }
        res.writeHead(302, { Location: target, ...corsHeaders(req) });
        res.end();
      });
    });
    lookup.on('error', () => {
      res.writeHead(302, { Location: `${base}/q/swagger-ui/`, ...corsHeaders(req) });
      res.end();
    });
    lookup.end();
    return;
  }
  if (clusterMatch || passThroughMatch) {
    const upstreamPath = clusterMatch
      ? `/dev-deployment-${clusterMatch[1]}${clusterMatch[2] || '/'}`
      : req.url;
    const upstream = http.request(
      {
        host: CLUSTER_INGRESS.hostname,
        port: CLUSTER_INGRESS.port || 80,
        path: upstreamPath,
        method: req.method,
        headers: { ...req.headers, host: CLUSTER_INGRESS.host },
      },
      (upRes) => {
        const cleaned = Object.fromEntries(
          Object.entries(upRes.headers).filter(
            ([k]) => !k.toLowerCase().startsWith('access-control-'),
          ),
        );
        res.writeHead(upRes.statusCode || 502, { ...cleaned, ...corsHeaders(req) });
        upRes.pipe(res);
      },
    );
    upstream.on('error', (err) => {
      console.error(`[proxy] ${CLUSTER_INGRESS.origin}${upstreamPath} → ${err.message}`);
      res.writeHead(502, { 'Content-Type': 'text/plain', ...corsHeaders(req) });
      res.end(`Bad gateway: ${err.message}`);
    });
    req.pipe(upstream);
    return;
  }

  // No matching route — return 404 with CORS headers (don't proxy random
  // paths to anything; the local Quarkus runtime that used to be the
  // catch-all is gone in the cloud-only flow).
  res.writeHead(404, { 'Content-Type': 'text/plain', ...corsHeaders(req) });
  res.end(`Not found: ${req.url}\nValid prefixes: /viewer/, /bpmn/, /cluster/<id>/`);
});

server.listen(PORT, () => {
  console.log(`[cors-proxy] listening on http://localhost:${PORT}`);
  console.log(`[cors-proxy]   /viewer/<id>/<p>  → in-proxy KIE read-only editor`);
  console.log(`[cors-proxy]   /start/<id>/<p>   → in-proxy "start instance" form`);
  console.log(`[cors-proxy]   /bpmn/*           → ${BPMN_DIR}`);
  console.log(`[cors-proxy]   /cluster/<id>/*   → ${CLUSTER_INGRESS.origin}/dev-deployment-<id>/*`);
  console.log(`[cors-proxy]   /dev-deployment-<id>/* → ${CLUSTER_INGRESS.origin}/dev-deployment-<id>/* (pass-through)`);
});
