const express = require('express');
const client = require('prom-client');
const { pool } = require('./db');

const app = express();
app.use(express.json());

// --- Prometheus metrics -----------------------------------------------------
const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestsTotal = new client.Counter({
  name: 'api_http_requests_total',
  help: 'Total number of HTTP requests handled by the API service',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const httpRequestDuration = new client.Histogram({
  name: 'api_http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.01, 0.05, 0.1, 0.3, 0.5, 1, 2, 5],
  registers: [register],
});

app.use((req, res, next) => {
  const start = process.hrtime();
  res.on('finish', () => {
    const [s, ns] = process.hrtime(start);
    const duration = s + ns / 1e9;
    const route = req.route ? req.route.path : req.path;
    httpRequestsTotal.inc({ method: req.method, route, status_code: res.statusCode });
    httpRequestDuration.observe({ method: req.method, route, status_code: res.statusCode }, duration);
  });
  next();
});

// --- Routes ------------------------------------------------------------------

app.get('/', (req, res) => {
  res.json({
    message: 'API service is running',
    hostname: require('os').hostname(),
    timestamp: new Date().toISOString(),
  });
});

// Liveness: is the process itself alive? No dependency checks on purpose -
// a slow database should never cause Kubernetes to kill and restart this pod.
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

// Readiness: can this pod actually serve traffic right now? Checks the
// database connection specifically, since that's this service's one real
// dependency - if the DB is unreachable, Kubernetes should stop routing
// traffic here until it recovers, without restarting the pod.
app.get('/ready', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.status(200).json({ status: 'ready' });
  } catch (err) {
    res.status(503).json({ status: 'not ready', error: err.message });
  }
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.get('/api/items', async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM items ORDER BY id DESC LIMIT 50');
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Creates an item and enqueues a background job for the worker service to
// pick up - this is the one real cross-service interaction in this demo:
// api and worker never talk to each other directly, they communicate
// through the shared database, the same way the task asks services to
// communicate "via Kubernetes services (DNS)" for the database itself.
app.post('/api/items', async (req, res) => {
  const { name } = req.body;
  if (!name || typeof name !== 'string') {
    return res.status(400).json({ error: 'name is required' });
  }
  try {
    const itemResult = await pool.query(
      'INSERT INTO items (name) VALUES ($1) RETURNING *',
      [name]
    );
    const item = itemResult.rows[0];
    await pool.query(
      'INSERT INTO jobs (item_id, payload) VALUES ($1, $2)',
      [item.id, `process-item:${item.id}`]
    );
    res.status(201).json(item);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = app;
