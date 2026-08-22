import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { JsonTransactionLog } from "../src/transaction-log.js";

test("tracks pending and updates entries", () => {
  const file = path.join(os.tmpdir(), `nexi-ecr-log-${Date.now()}-${Math.random()}.json`);
  const log = new JsonTransactionLog(file);

  log.append({ orderId: "A1", status: "pending", amountCents: 1 });
  assert.equal(log.findPending().length, 1);

  log.update("A1", { status: "approved" });
  assert.equal(log.findPending().length, 0);
  assert.equal(log.list()[0].status, "approved");

  fs.unlinkSync(file);
});
