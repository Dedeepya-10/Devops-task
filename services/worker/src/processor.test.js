const { processPendingJobs } = require('./processor');

function makePool(jobs) {
  return {
    query: jest.fn((sql) => {
      if (sql.startsWith('SELECT')) {
        return Promise.resolve({ rows: jobs });
      }
      return Promise.resolve({ rows: [] });
    }),
  };
}

describe('processPendingJobs', () => {
  it('does nothing when there are no pending jobs', async () => {
    const pool = makePool([]);
    const processed = await processPendingJobs(pool, () => {});
    expect(processed).toBe(0);
  });

  it('processes each pending job and marks it completed', async () => {
    const jobs = [
      { id: 1, item_id: 10, payload: 'process-item:10' },
      { id: 2, item_id: 11, payload: 'process-item:11' },
    ];
    const pool = makePool(jobs);
    const logs = [];
    const processed = await processPendingJobs(pool, (msg) => logs.push(msg));

    expect(processed).toBe(2);
    expect(logs.some((l) => l.includes('job 1'))).toBe(true);
    expect(logs.some((l) => l.includes('job 2'))).toBe(true);
    // 1 SELECT + (1 UPDATE jobs + 1 UPDATE items) per job = 1 + 4 = 5
    expect(pool.query).toHaveBeenCalledTimes(5);
  });
});
