#!/usr/bin/env node
// Tiny CORS-injecting reverse proxy with path-based routing. No deps.
//
// Routes /graphql (and /graphql/* and /graphiql*) to the Kogito Data Index
// (default http://localhost:8180) and everything else to the Quarkus runtime
// (default http://localhost:8080). Adds permissive CORS headers to every
// response so the KIE Management Console at http://localhost:8280 can connect.
//
//   PORT=8090 \
//   RUNTIME=http://localhost:8080 \
//   DATA_INDEX=http://localhost:8180 \
//   node cors-proxy.js

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { URL } = require('node:url');

const PORT = Number(process.env.PORT || 8090);
const RUNTIME = new URL(process.env.RUNTIME || 'http://localhost:8080');
const DATA_INDEX = new URL(process.env.DATA_INDEX || 'http://localhost:8180');
// The kind cluster's nginx ingress on host:80 — the Sandbox's Dev
// Deployments hang off path-prefixes there (e.g. /dev-deployment-<id>).
const CLUSTER_INGRESS = new URL(process.env.CLUSTER_INGRESS || 'http://localhost');

// Static file the BPMN Editor (local Sandbox on :8480) imports via URL.
// Served from the live source tree so analysts always pull the current file.
const BPMN_DIR = path.join(
  __dirname,
  'workflow',
  'src',
  'main',
  'resources',
  'org',
  'acme',
  'travels',
);

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

function pickTarget(reqUrl) {
  // Anything graphql-ish goes to data-index; everything else to the runtime.
  if (/^\/(graphql|graphiql)(\/|$|\?)/.test(reqUrl)) return DATA_INDEX;
  return RUNTIME;
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
  // visualizer; for the local approval process the local Mgmt Console at
  // :8280 already does that via kie-addons-quarkus-process-svg.
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

  // /bpmn/<filename>.bpmn — serve from workflow source tree so the BPMN
  // Editor on :8480 can import the live file. Path-traversal-guarded.
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
  // and forward to the kind ingress on :80. Lets a Mgmt Console connect to
  // a Sandbox-deployed app via this proxy so CORS works the same as for
  // the local runtime.
  const clusterMatch = req.url.match(/^\/cluster\/([A-Za-z0-9_-]+)(\/.*)?$/);
  let target;
  let upstreamPath;
  if (clusterMatch) {
    target = CLUSTER_INGRESS;
    upstreamPath = `/dev-deployment-${clusterMatch[1]}${clusterMatch[2] || '/'}`;
  } else {
    target = pickTarget(req.url);
    upstreamPath = req.url;
  }

  const upstream = http.request(
    {
      host: target.hostname,
      port: target.port || 80,
      path: upstreamPath,
      method: req.method,
      headers: { ...req.headers, host: target.host },
    },
    (upRes) => {
      const cleaned = Object.fromEntries(
        Object.entries(upRes.headers).filter(
          ([k]) => !k.toLowerCase().startsWith('access-control-'),
        ),
      );
      const headers = { ...cleaned, ...corsHeaders(req) };
      res.writeHead(upRes.statusCode || 502, headers);
      upRes.pipe(res);
    },
  );

  upstream.on('error', (err) => {
    console.error(`[proxy] ${target.origin}${req.url} → ${err.message}`);
    res.writeHead(502, { 'Content-Type': 'text/plain', ...corsHeaders(req) });
    res.end(`Bad gateway: ${err.message}`);
  });

  req.pipe(upstream);
});

server.listen(PORT, () => {
  console.log(`[cors-proxy] listening on http://localhost:${PORT}`);
  console.log(`[cors-proxy]   /graphql*           → ${DATA_INDEX.origin}`);
  console.log(`[cors-proxy]   /bpmn/*             → ${BPMN_DIR}`);
  console.log(`[cors-proxy]   /cluster/<id>/*     → ${CLUSTER_INGRESS.origin}/dev-deployment-<id>/*`);
  console.log(`[cors-proxy]   /viewer/<id>/<p>    → in-proxy KIE read-only editor`);
  console.log(`[cors-proxy]   everything else     → ${RUNTIME.origin}`);
});
