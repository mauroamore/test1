import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { createDiagnosticReport } from "../src/diagnostics.js";

test("creates diagnostic report file", async () => {
  const outputPath = path.join(os.tmpdir(), `nexi-ecr-diagnostic-${Date.now()}-${Math.random()}.json`);
  const logPath = path.join(os.tmpdir(), `nexi-ecr-diagnostic-log-${Date.now()}-${Math.random()}.json`);
  const fakeClient = {
    options: {
      host: "127.0.0.1",
      port: 8081,
      terminalId: "00000000",
      cashRegisterId: "00000001",
      transactionLogPath: logPath
    },
    async status() {
      return { terminalId: "00000000", messageCode: "s", raw: "ok" };
    },
    async lastResult() {
      return { ok: true, raw: "last" };
    }
  };

  const result = await createDiagnosticReport(fakeClient, { outputPath, includeLastResult: true });
  assert.equal(result.outputPath, outputPath);
  assert.equal(result.report.status.messageCode, "s");
  assert.equal(fs.existsSync(outputPath), true);

  fs.unlinkSync(outputPath);
});
