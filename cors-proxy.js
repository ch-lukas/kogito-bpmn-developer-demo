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
const { URL } = require('node:url');

const PORT = Number(process.env.PORT || 8090);
const RUNTIME = new URL(process.env.RUNTIME || 'http://localhost:8080');
const DATA_INDEX = new URL(process.env.DATA_INDEX || 'http://localhost:8180');

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

  const target = pickTarget(req.url);

  const upstream = http.request(
    {
      host: target.hostname,
      port: target.port || 80,
      path: req.url,
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
  console.log(`[cors-proxy]   /graphql*  → ${DATA_INDEX.origin}`);
  console.log(`[cors-proxy]   everything else → ${RUNTIME.origin}`);
});
