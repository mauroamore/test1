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
