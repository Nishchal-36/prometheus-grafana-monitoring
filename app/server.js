"use strict";

const http = require("http");
const os = require("os");
const { URL } = require("url");
const client = require("prom-client");

const PORT = parseInt(process.env.PORT || "3000", 10);
const SERVER_NAME = process.env.SERVER_NAME || os.hostname();

client.collectDefaultMetrics();

const httpRequests = new client.Counter({
  name: "http_requests_total",
  help: "Total HTTP requests handled",
  labelNames: ["method", "route", "status"],
});

const httpDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5],
});

const httpInflight = new client.Gauge({
  name: "http_inflight_requests",
  help: "In-flight HTTP requests",
});

const jobsProcessed = new client.Counter({
  name: "app_jobs_processed_total",
  help: "Demo jobs processed by the app",
  labelNames: ["result"],
});

const cpuBurnSeconds = new client.Counter({
  name: "app_cpu_burn_seconds_total",
  help: "Total seconds spent burning CPU via /burn",
});

const buildInfo = new client.Gauge({
  name: "app_build_info",
  help: "Build info, constant 1 with labels",
  labelNames: ["version", "hostname"],
});
buildInfo.labels("1.0.0", os.hostname()).set(1);

const KNOWN_ROUTES = new Set(["/", "/health", "/metrics", "/work", "/burn", "/info"]);

function routeOf(pathname) {
  return KNOWN_ROUTES.has(pathname) ? pathname : "other";
}

function busyWait(ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    Math.sqrt(Math.random() * Number.MAX_SAFE_INTEGER);
  }
}

function send(res, status, body, type = "text/plain; charset=utf-8") {
  res.writeHead(status, { "Content-Type": type });
  res.end(body);
}

function page() {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>${SERVER_NAME} - monlab demo</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 40px; background: #0f172a; color: #e2e8f0; }
    h1 { color: #38bdf8; }
    button { margin: 6px 8px 6px 0; padding: 10px 16px; border-radius: 8px; border: 0; cursor: pointer;
             background: #1e40af; color: white; font-size: 14px; }
    button:hover { background: #2563eb; }
    code { background: #1e293b; padding: 2px 6px; border-radius: 4px; }
    #out { margin-top: 16px; white-space: pre-wrap; color: #94a3b8; }
  </style>
</head>
<body>
  <h1>${SERVER_NAME} &mdash; monitored demo app</h1>
  <p>This app is scraped by Prometheus at <code>/metrics</code>. Generate load below and watch the Grafana dashboards react.</p>
  <div>
    <button onclick="call('/work?ms=200')">Run 1 job (200ms)</button>
    <button onclick="call('/work?ms=800')">Run 1 slow job (800ms)</button>
    <button onclick="call('/burn?seconds=10')">Burn CPU 10s</button>
    <button onclick="call('/health')">Health</button>
    <button onclick="call('/info')">Info</button>
  </div>
  <pre id="out"></pre>
  <script>
    async function call(url) {
      const out = document.getElementById('out');
      out.textContent = 'calling ' + url + ' ...';
      const t0 = performance.now();
      try {
        const r = await fetch(url);
        out.textContent = url + ' -> ' + r.status + ' in ' + Math.round(performance.now() - t0) + ' ms\\n' + await r.text();
      } catch (e) {
        out.textContent = url + ' -> ERROR ' + e;
      }
    }
  </script>
</body>
</html>`;
}

const server = http.createServer((req, res) => {
  const started = process.hrtime.bigint();
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  const route = routeOf(url.pathname);

  httpInflight.inc();
  res.on("finish", () => {
    httpInflight.dec();
    const seconds = Number(process.hrtime.bigint() - started) / 1e9;
    httpRequests.labels(req.method, route, String(res.statusCode)).inc();
    if (route !== "/metrics") {
      httpDuration.labels(req.method, route).observe(seconds);
    }
  });

  if (route === "/") {
    return send(res, 200, page(), "text/html; charset=utf-8");
  }

  if (route === "/health") {
    return send(res, 200, JSON.stringify({ status: "ok", server: SERVER_NAME, uptime: process.uptime() }));
  }

  if (route === "/info") {
    return send(res, 200, JSON.stringify({
      server: SERVER_NAME,
      hostname: os.hostname(),
      platform: `${os.platform()} ${os.release()}`,
      cpus: os.cpus().length,
      totalMemMB: Math.round(os.totalmem() / 1024 / 1024),
      node: process.version,
      pid: process.pid,
    }, null, 2));
  }

  if (route === "/metrics") {
    return client.register.metrics()
      .then((m) => send(res, 200, m, client.register.contentType))
      .catch((e) => send(res, 500, String(e)));
  }

  if (route === "/work") {
    const ms = Math.min(Math.max(parseInt(url.searchParams.get("ms") || "200", 10), 10), 5000);
    busyWait(ms);
    jobsProcessed.labels("success").inc();
    return send(res, 200, `job done in ~${ms}ms on ${SERVER_NAME}`);
  }

  if (route === "/burn") {
    const seconds = Math.min(Math.max(parseFloat(url.searchParams.get("seconds") || "10"), 1), 120);
    const deadline = Date.now() + seconds * 1000;
    while (Date.now() < deadline) {
      Math.sqrt(Math.random() * Number.MAX_SAFE_INTEGER);
    }
    cpuBurnSeconds.inc(seconds);
    return send(res, 200, `burned CPU for ~${seconds}s on ${SERVER_NAME}`);
  }

  send(res, 404, "not found");
});

server.listen(PORT, () => {
  console.log(`[${SERVER_NAME}] demo app listening on :${PORT}`);
});
