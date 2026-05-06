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
  // so redirect to swagger-ui anchored on the first process — Kogito exposes
  // the process list at /management/processes. Falls back to swagger root if
  // the lookup fails.
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
            target = `${base}/q/swagger-ui/#/${encodeURIComponent(ids[0])}`;
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
  console.log(`[cors-proxy]   /bpmn/*           → ${BPMN_DIR}`);
  console.log(`[cors-proxy]   /cluster/<id>/*   → ${CLUSTER_INGRESS.origin}/dev-deployment-<id>/*`);
  console.log(`[cors-proxy]   /dev-deployment-<id>/* → ${CLUSTER_INGRESS.origin}/dev-deployment-<id>/* (pass-through)`);
});
