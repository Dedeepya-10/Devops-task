const JOB_BATCH_SIZE = 5;

// Simulates doing real work on a job - in a real system this is where
// you'd call an external API, resize an image, send an email, etc.
async function doWork(job) {
  await new Promise((resolve) => setTimeout(resolve, 200));
  return `handled ${job.payload}`;
}

// Processes one batch of pending jobs. Returns how many were processed,
// so the caller (and the metrics layer) can report on progress.
async function processPendingJobs(pool, log = console.log) {
  const { rows: jobs } = await pool.query(
    "SELECT * FROM jobs WHERE status = 'pending' ORDER BY id ASC LIMIT $1",
    [JOB_BATCH_SIZE]
  );

  let processed = 0;
  for (const job of jobs) {
    try {
      const result = await doWork(job);
      await pool.query(
        "UPDATE jobs SET status = 'completed', processed_at = now() WHERE id = $1",
        [job.id]
      );
      if (job.item_id) {
        await pool.query(
          "UPDATE items SET status = 'processed' WHERE id = $1",
          [job.item_id]
        );
      }
      log(`job ${job.id}: ${result}`);
      processed += 1;
    } catch (err) {
      await pool.query(
        "UPDATE jobs SET status = 'failed', processed_at = now() WHERE id = $1",
        [job.id]
      );
      log(`job ${job.id} failed: ${err.message}`);
    }
  }
  return processed;
}

module.exports = { processPendingJobs, doWork, JOB_BATCH_SIZE };
