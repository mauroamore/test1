const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { TableLockStore } = require("../src/table-locks");

const source = fs.readFileSync(path.join(__dirname, "../server.js"), "utf8");
const start = source.indexOf('        if (operation === "commit_order") {');
const end = source.indexOf('        if (["monitor_cycle_line"', start);
assert.ok(start >= 0 && end > start);
const handler = source.slice(start, end);

function fixture(tables = []) {
  const sharedState = { tables: structuredClone(tables), deliveryOrders: [], settings: {}, stateRevision: 1 };
  const tableLocks = new TableLockStore({ ttlMs: 15000 });
  const lease = tableLocks.acquire({ tableId: "5", token: "device-a" });
  let result;
  const context = {
    sharedState, tableLocks, structuredClone, response: {}, operation: "commit_order",
    stateForClient: value => structuredClone(value),
    sendJson: (_response, status, body) => { result = { status, body }; },
    reopenDismissedMonitorCoursesForNewLines: () => {}, mergeMonitorFields: () => {},
    persistStateFiles: () => {}, broadcastLocal: () => {},
    pushStateSnapshot: async () => {}, publishRealtimeEvent: () => {}
  };
  const execute = vm.runInNewContext(`(payload) => { const currentRevision = sharedState.stateRevision; ${handler} }`, context);
  const commit = overrides => {
    execute({ order: { id: 5, covers: 2, sentCovers: 2, items: [{ key: "dish-1", name: "Test", qty: 1, sentQty: 1 }] }, lockToken: "device-a", lockId: lease.lockId, ...overrides });
    return result;
  };
  return { commit, sharedState, tableLocks, lease };
}

test("the first kitchen send creates a table order with a valid lease even before reservations polling", () => {
  const { commit, sharedState } = fixture([{ id: 2, items: [{ key: "other" }] }]);
  assert.equal(commit().status, 200);
  assert.equal(sharedState.tables.length, 2);
  assert.equal(sharedState.tables.find(t => t.id === 5).items[0].key, "dish-1");
  assert.equal(sharedState.tables.find(t => t.id === 2).items[0].key, "other");
});

test("first kitchen send still rejects a revoked or wrong lease", () => {
  const { commit, tableLocks, lease, sharedState } = fixture();
  assert.equal(commit({ lockId: "wrong" }).status, 409);
  tableLocks.acquire({ tableId: "5", token: "device-b", replaceLockId: lease.lockId });
  assert.equal(commit().status, 409);
  assert.equal(sharedState.tables.length, 0);
});

test("changes to an existing order still require a matching base revision", () => {
  const { commit, sharedState } = fixture([{ id: 5, sentCovers: 2, items: [{ key: "original", sentQty: 1, kitchenStatus: "Completo" }] }]);
  const result = commit({ baseOrderRevision: JSON.stringify({ sentCovers: 0, lines: [] }) });
  assert.equal(result.status, 409);
  assert.equal(result.body.orderConflict, true);
  assert.equal(sharedState.tables[0].items[0].key, "original");
});
