const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { TableLockStore } = require("../src/table-locks");
const { normalizeDeliverooOrder } = require("../src/glovo-order-normalization");
const { mergeMonitorFields } = require("../src/monitor-state-merge");

const source = fs.readFileSync(path.join(__dirname, "../server.js"), "utf8");
const start = source.indexOf('        if (operation === "commit_order") {');
const end = source.indexOf('        if (["monitor_cycle_line"', start);
assert.ok(start >= 0 && end > start);
const handler = source.slice(start, end);

function fixture(tables = [], deliveryOrders = [], managementAuthorized = true) {
  const sharedState = { tables: structuredClone(tables), deliveryOrders: structuredClone(deliveryOrders), settings: {}, stateRevision: 1 };
  const tableLocks = new TableLockStore({ ttlMs: 15000 });
  const lease = tableLocks.acquire({ tableId: "5", token: "device-a" });
  let result;
  const context = {
    sharedState, tableLocks, structuredClone, request: {}, response: {}, operation: "commit_order",
    mutationAuthorized: () => managementAuthorized,
    stateForClient: value => structuredClone(value),
    sendJson: (_response, status, body) => { result = { status, body }; },
    reopenDismissedMonitorCoursesForNewLines: () => {}, mergeMonitorFields,
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

test("an imported Deliveroo order can be sent to the kitchen without a table lock", () => {
  const order = normalizeDeliverooOrder({
    id: "qa-deliveroo", order_number: "123", status: "accepted",
    amount: { fractional: 700, currency_code: "EUR" },
    items: [{ name: "1 Piatto test", quantity: 1, unit_price: { fractional: 700 }, modifiers: [] }]
  }, new Map([["1", { id: 1, name: "1 Piatto test", price: 7, category: "Test" }]]));
  const { commit, sharedState } = fixture([{ id: 2, items: [] }], [order]);
  const incoming = structuredClone(order);
  incoming.status = "Preparazione";
  incoming.items[0].sentQty = incoming.items[0].qty;
  const result = commit({ order: incoming, lockToken: null, lockId: null });
  assert.equal(result.status, 200);
  assert.equal(sharedState.deliveryOrders.length, 1);
  assert.equal(sharedState.deliveryOrders[0].items[0].sentQty, 1);
  assert.equal(sharedState.deliveryOrders[0].total, 7);
  assert.equal(sharedState.deliveryOrders[0].source, "deliveroo");
  assert.equal(sharedState.tables.length, 1);
  assert.equal(sharedState.tables[0].id, 2);
});

for (const source of ["glovo", "justeat", "hubrise", "sigonella"]) {
  test(`existing ${source} orders use the same kitchen commit route`, () => {
    const order = { id: `${source}-123`, source, externalOrderId: "123", total: 7, externalStatus: "accepted", items: [{ key: "dish", qty: 1, sentQty: 0, kitchenStatus: "Completo" }] };
    const { commit, sharedState } = fixture([], [order]);
    const result = commit({ order: { ...structuredClone(order), status: "Preparazione", items: [{ key: "dish", qty: 1, sentQty: 1, kitchenStatus: "Da preparare" }] }, lockToken: null, lockId: null });
    assert.equal(result.status, 200);
    assert.equal(sharedState.deliveryOrders[0].items[0].kitchenStatus, "Completo");
    assert.equal(sharedState.deliveryOrders[0].externalStatus, "accepted");
  });
}

test("management commit cannot create an imported order or change its platform identity", () => {
  const order = { id: "deliveroo-123", source: "deliveroo", externalOrderId: "123", items: [] };
  const empty = fixture();
  assert.equal(empty.commit({ order }).status, 404);
  assert.equal(empty.sharedState.deliveryOrders.length, 0);
  const existing = fixture([], [order]);
  assert.equal(existing.commit({ order: { ...order, source: "manual" } }).status, 403);
  assert.equal(existing.commit({ order: { ...order, externalOrderId: "456" } }).status, 403);
});

test("a monitor-only credential must not authorize a management order commit", () => {
  const order = { id: "deliveroo-123", source: "deliveroo", externalOrderId: "123", items: [] };
  const { commit } = fixture([], [order], false);
  assert.equal(commit({ order }).status, 403);
});

test("delivery commits preserve newer platform status and payload", () => {
  const order = { id: "deliveroo-123", source: "deliveroo", externalOrderId: "123", externalStatus: "ready", deliverooPayload: { status: "ready" }, items: [] };
  const { commit, sharedState } = fixture([], [order]);
  assert.equal(commit({ order: { ...order, externalStatus: "accepted", deliverooPayload: { status: "accepted" } } }).status, 200);
  assert.equal(sharedState.deliveryOrders[0].externalStatus, "ready");
  assert.deepEqual(sharedState.deliveryOrders[0].deliverooPayload, { status: "ready" });
});

test("delivery commits still reject changes based on an outdated kitchen revision", () => {
  const order = { id: "deliveroo-123", source: "deliveroo", externalOrderId: "123", items: [{ key: "dish", qty: 1, sentQty: 1 }] };
  const { commit, sharedState } = fixture([], [order]);
  const result = commit({ order, baseOrderRevision: JSON.stringify({ sentCovers: 0, lines: [] }) });
  assert.equal(result.status, 409);
  assert.equal(result.body.orderConflict, true);
  assert.equal(sharedState.stateRevision, 1);
});

test("manual pickup commits remain supported without a table lease", () => {
  const order = { id: "manual-123", source: "manual", items: [] };
  const { commit, sharedState } = fixture();
  assert.equal(commit({ order, lockToken: null, lockId: null }).status, 200);
  assert.equal(sharedState.deliveryOrders[0].id, "manual-123");
  assert.equal(sharedState.tables.length, 0);
});
