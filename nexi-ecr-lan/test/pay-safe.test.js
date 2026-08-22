import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { NexiEcrClient } from "../src/client.js";
import { EcrConnectionError } from "../src/errors.js";
import { JsonTransactionLog } from "../src/transaction-log.js";

test("paySafe marks lost outcome as uncertain", async () => {
  const file = path.join(os.tmpdir(), `nexi-ecr-paysafe-${Date.now()}-${Math.random()}.json`);
  const client = new NexiEcrClient({
    host: "127.0.0.1",
    port: 8081,
    terminalId: "00000000",
    cashRegisterId: "00000001",
    transactionLogPath: file
  });
  client.pay = async () => {
    throw new EcrConnectionError("ECR socket closed before a complete packet");
  };

  await assert.rejects(() => client.paySafe({ orderId: "A1", amountCents: 1 }), EcrConnectionError);
  assert.equal(new JsonTransactionLog(file).list()[0].status, "uncertain");

  fs.unlinkSync(file);
});
