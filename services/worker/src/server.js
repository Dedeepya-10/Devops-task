const { app, jobsProcessedTotal, lastPollTimestamp } = require('./app');
const { pool } = require('./db');
const { processPendingJobs } = require('./processor');

const PORT = process.env.PORT || 4100;
const POLL_INTERVAL_MS = Number(process.env.POLL_INTERVAL_MS || 5000);

async function poll() {
  try {
    const processed = await processPendingJobs(pool);
    lastPollTimestamp.set(Date.now() / 1000);
    if (processed > 0) {
      jobsProcessedTotal.inc(processed);
      console.log(`Processed ${processed} job(s)`);
    }
  } catch (err) {
    console.error('Polling failed:', err.message);
  }
}

app.listen(PORT, () => {
  console.log(`Worker health/metrics server listening on port ${PORT}`);
  setInterval(poll, POLL_INTERVAL_MS);
  poll();
});
