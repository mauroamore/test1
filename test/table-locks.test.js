const test = require("node:test");
const assert = require("node:assert/strict");
const { TableLockStore } = require("../src/table-locks");

function fixture() {
  let time = 1000;
  let sequence = 0;
  const locks = new TableLockStore({ ttlMs: 15000, now: () => time, newId: () => `lease-${++sequence}` });
  return { locks, advance: ms => { time += ms; } };
}

test("another device must confirm the current lease before taking over", () => {
  const { locks } = fixture();
  const first = locks.acquire({ tableId: "11", token: "device-a" });
  assert.equal(first.ok, true);
  const conflict = locks.acquire({ tableId: "11", token: "device-b" });
  assert.equal(conflict.ok, false);
  assert.equal(conflict.lockId, first.lockId);
  const second = locks.acquire({ tableId: "11", token: "device-b", replaceLockId: conflict.lockId });
  assert.equal(second.ok, true);
  assert.notEqual(second.lockId, first.lockId);
  assert.equal(locks.get("11").token, "device-b");
});

test("a confirmation cannot replace a newer owner's lease", () => {
  const { locks } = fixture();
  const first = locks.acquire({ tableId: "11", token: "a" });
  const second = locks.acquire({ tableId: "11", token: "b", replaceLockId: first.lockId });
  assert.equal(locks.acquire({ tableId: "11", token: "c", replaceLockId: first.lockId }).ok, false);
  assert.equal(locks.get("11").lockId, second.lockId);
});

test("old heartbeats and releases cannot undo a takeover, even after the new owner closes", () => {
  const { locks, advance } = fixture();
  const first = locks.acquire({ tableId: "11", token: "a" });
  const second = locks.acquire({ tableId: "11", token: "b", replaceLockId: first.lockId });
  assert.equal(locks.acquire({ tableId: "11", token: "a", lockId: first.lockId }).ok, false);
  locks.release({ tableId: "11", token: "a", lockId: first.lockId });
  assert.equal(locks.get("11").lockId, second.lockId);
  locks.release({ tableId: "11", token: "b", lockId: second.lockId });
  advance(30000);
  assert.equal(locks.acquire({ tableId: "11", token: "a" }).ok, false);
  assert.equal(locks.acquire({ tableId: "11", token: "a", lockId: first.lockId }).ok, false);
  assert.equal(locks.acquire({ tableId: "11", token: "a", explicitAcquire: true }).ok, true);
});

test("a renewal may recover its expired lease, but cannot renew a released one", () => {
  const { locks, advance } = fixture();
  const first = locks.acquire({ tableId: "11", token: "a" });
  advance(16000);
  assert.equal(locks.acquire({ tableId: "11", token: "a", lockId: first.lockId }).lockId, first.lockId);
  locks.release({ tableId: "11", token: "a", lockId: first.lockId });
  assert.equal(locks.acquire({ tableId: "11", token: "a", lockId: first.lockId }).ok, false);
});

test("lease summaries disclose no owner token and keep unrelated tables unchanged", () => {
  const { locks, advance } = fixture();
  const first = locks.acquire({ tableId: "11", token: "a" });
  locks.acquire({ tableId: "2", token: "c" });
  locks.acquire({ tableId: "11", token: "b", replaceLockId: first.lockId });
  assert.equal(locks.get("2").token, "c");
  assert.equal(JSON.stringify(locks.list()).includes('"token"'), false);
  advance(16000);
  assert.deepEqual(locks.list(), {});
});
