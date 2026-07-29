jest.mock('./db', () => ({
  pool: { query: jest.fn() },
}));

const request = require('supertest');
const { pool } = require('./db');
const app = require('./app');

beforeEach(() => {
  pool.query.mockReset();
});

describe('GET /health', () => {
  it('returns ok without touching the database', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
    expect(pool.query).not.toHaveBeenCalled();
  });
});

describe('GET /ready', () => {
  it('returns 200 when the database responds', async () => {
    pool.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(app).get('/ready');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ready');
  });

  it('returns 503 when the database is unreachable', async () => {
    pool.query.mockRejectedValueOnce(new Error('connection refused'));
    const res = await request(app).get('/ready');
    expect(res.status).toBe(503);
    expect(res.body.status).toBe('not ready');
  });
});

describe('GET /api/items', () => {
  it('returns the list of items', async () => {
    pool.query.mockResolvedValueOnce({ rows: [{ id: 1, name: 'widget' }] });
    const res = await request(app).get('/api/items');
    expect(res.status).toBe(200);
    expect(res.body).toEqual([{ id: 1, name: 'widget' }]);
  });
});

describe('POST /api/items', () => {
  it('rejects a missing name', async () => {
    const res = await request(app).post('/api/items').send({});
    expect(res.status).toBe(400);
  });

  it('creates an item and enqueues a job', async () => {
    pool.query
      .mockResolvedValueOnce({ rows: [{ id: 1, name: 'widget' }] })
      .mockResolvedValueOnce({ rows: [] });
    const res = await request(app).post('/api/items').send({ name: 'widget' });
    expect(res.status).toBe(201);
    expect(res.body).toEqual({ id: 1, name: 'widget' });
    expect(pool.query).toHaveBeenCalledTimes(2);
  });
});

describe('GET /metrics', () => {
  it('exposes Prometheus metrics', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.text).toMatch(/api_http_requests_total/);
  });
});
