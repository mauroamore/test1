import fs from "node:fs";
import path from "node:path";
import { JsonTransactionLog } from "./transaction-log.js";

export async function createDiagnosticReport(client, options = {}) {
  const startedAt = new Date().toISOString();
  const log = new JsonTransactionLog(client.options.transactionLogPath);
  const report = {
    startedAt,
    config: {
      host: client.options.host,
      port: client.options.port,
      terminalId: client.options.terminalId,
      cashRegisterId: client.options.cashRegisterId,
      lrcMode: client.options.lrcMode ?? "stxetx"
    },
    pending: log.findPending(),
    status: null,
    lastResult: null,
    errors: []
  };

  try {
    report.status = await client.status();
  } catch (error) {
    report.errors.push(serializeError("status", error));
  }

  if (options.includeLastResult) {
    try {
      report.lastResult = await client.lastResult();
    } catch (error) {
      report.errors.push(serializeError("lastResult", error));
    }
  }

  const outputPath = path.resolve(options.outputPath ?? `diagnostic-${startedAt.replace(/[:.]/g, "-")}.json`);
  fs.writeFileSync(outputPath, JSON.stringify(report, null, 2));
  return { outputPath, report };
}

function serializeError(scope, error) {
  return {
    scope,
    name: error?.name,
    message: error instanceof Error ? error.message : String(error),
    details: error?.details
  };
}
