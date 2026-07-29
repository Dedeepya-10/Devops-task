const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5432),
  user: process.env.PGUSER || 'postgres',
  password: process.env.PGPASSWORD || 'postgres',
  database: process.env.PGDATABASE || 'appdb',
  max: 5,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 3000,
});

module.exports = { pool };
