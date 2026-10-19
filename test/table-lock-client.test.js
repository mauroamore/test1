const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const html = fs.readFileSync(path.join(__dirname, "../outputs/gestione-comande-ristorante.html"), "utf8");
const start = html.indexOf("    async function ensureTableLockForSend()");
const end = html.indexOf("    function releaseTableLock()", start);
assert.ok(start >= 0 && end > start);
const sendGuard = html.slice(start, end);

test("send stays blocked if the lease is lost during the final renewal", async () => {
  const context = { REMOTE_MODE: false, localOrderDraftId: 1, tableLockLost: false, alert: () => assert.fail("use the inline notice") };
  context.acquireTableLock = async () => { context.tableLockLost = true; return false; };
  const check = vm.runInNewContext(`${sendGuard}; ensureTableLockForSend`, context);
  assert.equal(await check(), false);
});

test("a known lost lease does not attempt to reacquire before sending", async () => {
  const check = vm.runInNewContext(`${sendGuard}; ensureTableLockForSend`, {
    REMOTE_MODE: false, localOrderDraftId: 1, tableLockLost: true,
    acquireTableLock: () => assert.fail("must not reacquire"), alert: () => assert.fail("use the inline notice")
  });
  assert.equal(await check(), false);
});

test("a valid lease still permits sending", async () => {
  const check = vm.runInNewContext(`${sendGuard}; ensureTableLockForSend`, {
    REMOTE_MODE: false, localOrderDraftId: 1, tableLockLost: false,
    acquireTableLock: async () => true, alert: () => assert.fail("unexpected alert")
  });
  assert.equal(await check(), true);
});

test("a failed kitchen commit leaves the dishes unsent and retryable", async () => {
  const start = html.indexOf("    async function sendOrderToKitchen(order)");
  const end = html.indexOf("    async function sendDeliveryOrderToKitchen", start);
  assert.ok(start >= 0 && end > start);
  const order = { id: 5, status: "Nuova", items: [{ key: "test", qty: 1, sentQty: 0 }] };
  const context = {
    structuredClone, localOrderDraftId: 5, localOrderDraft: order, state: { courseActivationOrder: [] },
    markLinesSentToKitchen: o => { o.items[0].sentQty = 1; },
    publishLocalOrderDraft: async () => false,
    persistLocalOrderDraft: () => {}, renderOrder: () => {},
    printOrderToConfiguredMonitors: () => assert.fail("a rejected order must not print")
  };
  const send = vm.runInNewContext(`${html.slice(start, end)}; sendOrderToKitchen`, context);
  assert.equal(await send(order), false);
  assert.equal(order.items[0].sentQty, 0);
  assert.equal(order.status, "Nuova");
  assert.equal(context.localOrderDraft.items[0].sentQty, 0);
});

for (const [status, failure, expected] of [
  [401, {}, /accesso al server/],
  [409, { lockExpired: true }, /blocco della comanda/],
  [409, { orderConflict: true }, /modificata da un'altra istanza/],
  [502, { error: "Servizio non disponibile" }, /Servizio non disponibile/],
  [0, {}, /non e' raggiungibile/]
]) {
  test(`failed commit reports its actual cause (${status}, ${JSON.stringify(failure)})`, async () => {
    const start = html.indexOf("    async function publishLocalOrderDraft(order)");
    const end = html.indexOf("    function loadState()", start);
    assert.ok(start >= 0 && end > start);
    const messages = [];
    const context = {
      structuredClone, localOrderDraftBaseRevision: null, state: { stateRevision: 1 },
      INSTANCE_LOCK_TOKEN: "qa", tableLockLeaseId: "qa-lease",
      commitLocalOrderDraft: () => {}, persistLocalOrderDraft: () => {}, render: () => {},
      alert: message => messages.push(message),
      fetch: async url => {
        if (url === "/api/state") return { ok: true, json: async () => ({ state: { tables: [] }, stateRevision: 1 }) };
        if (!status) throw new Error("offline");
        return { ok: false, status, json: async () => failure };
      }
    };
    const publish = vm.runInNewContext(`${html.slice(start, end)}; publishLocalOrderDraft`, context);
    assert.equal(await publish({ id: 5, items: [] }), false);
    assert.match(messages[0], expected);
    if (!failure.orderConflict) assert.doesNotMatch(messages[0], /modificata da un'altra istanza/);
  });
}
