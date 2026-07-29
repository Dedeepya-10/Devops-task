const app = require('./app');
const { init } = require('./db');

const PORT = process.env.PORT || 4000;
const INIT_RETRIES = 10;
const INIT_RETRY_DELAY_MS = 3000;

// Kubernetes gives no guarantee that the database's Service DNS is
// resolvable, or that Postgres is actually accepting connections, by the
// time this pod starts - a StatefulSet and a Deployment starting around
// the same time is a race, not an ordering guarantee. Retrying with a
// short backoff here is simpler than an initContainer for this demo, and
// covers both "DNS not ready yet" and "Postgres still starting up".
async function initWithRetry() {
  for (let attempt = 1; attempt <= INIT_RETRIES; attempt += 1) {
    try {
      await init();
      console.log('Database schema ready');
      return;
    } catch (err) {
      console.error(`DB init attempt ${attempt}/${INIT_RETRIES} failed: ${err.message}`);
      if (attempt < INIT_RETRIES) {
        await new Promise((resolve) => setTimeout(resolve, INIT_RETRY_DELAY_MS));
      }
    }
  }
  console.error('Giving up on DB schema init - /ready will report not-ready until the DB recovers');
}

async function start() {
  await initWithRetry();
  app.listen(PORT, () => {
    console.log(`API service listening on port ${PORT}`);
  });
}

start();
