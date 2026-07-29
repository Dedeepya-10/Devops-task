const express = require('express');
const client = require('prom-client');
const { pool } = require('./db');

const app = express();

const register = new client.Registry();
client.collectDefaultMetrics({ register });

const jobsProcessedTotal = new client.Counter({
  name: 'worker_jobs_processed_total',
  help: 'Total number of jobs successfully processed by the worker',
  registers: [register],
});

const jobsFailedTotal = new client.Counter({
  name: 'worker_jobs_failed_total',
  help: 'Total number of jobs that failed processing',
  registers: [register],
});

const lastPollTimestamp = new client.Gauge({
  name: 'worker_last_poll_timestamp_seconds',
  help: 'Unix timestamp of the last time the worker polled for jobs',
  registers: [register],
});

// Liveness: is the worker process itself alive and not deadlocked?
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

// Readiness: can the worker actually reach the database to pick up jobs?
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

module.exports = { app, jobsProcessedTotal, jobsFailedTotal, lastPollTimestamp };
