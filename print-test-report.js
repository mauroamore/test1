const fs = require("fs");
const path = require("path");
const epson = require("./EpsonFiscalClient.js");

function timestampForFile(date = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate())
  ].join("") + "-" + [
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds())
  ].join("");
}

function readEnv(name, fallback = "") {
  return process.env[name] || fallback;
}

(async () => {
  const startedAt = new Date();
  const printerHost = readEnv("PRINTER_HOST");
  const amount = readEnv("AMOUNT", "0.01");
  const department = readEnv("DEPARTMENT", "2");
  const paymentType = readEnv("PAYMENT_TYPE");
  const paymentDescription = readEnv("PAYMENT_DESCRIPTION", "");
  const reportDir = path.join(__dirname, "reports");

  if (!printerHost) throw new Error("PRINTER_HOST non impostato");
  if (!paymentType) throw new Error("PAYMENT_TYPE non impostato");

  const request = {
    printerHost,
    amount,
    vat: "10%",
    department,
    itemDescription: "Test IVA 10",
    paymentType,
    paymentDescription
  };
  const receiptPayload = {
    items: [{
      description: request.itemDescription,
      quantity: "1",
      unitPrice: amount,
      department
    }],
    payment: {
      description: paymentDescription,
      amount,
      paymentType,
      index: "1"
    }
  };
  const fiscalReceiptXml = epson.buildFiscalReceiptXml(receiptPayload);

  let response;
  let error;
  try {
    response = await epson.printFiscalReceipt(printerHost, receiptPayload);
  } catch (err) {
    error = {
      name: err.name,
      message: err.message,
      stack: err.stack
    };
  }

  const finishedAt = new Date();
  const report = {
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    request,
    fiscalReceiptXml,
    result: {
      success: Boolean(response && response.success),
      code: response ? response.code : "CLIENT ERROR",
      status: response ? response.status : "",
      addInfo: response ? response.addInfo : {},
      lines: response ? response.lines : []
    },
    response,
    error
  };

  fs.mkdirSync(reportDir, { recursive: true });
  const reportPath = path.join(reportDir, `scontrino-test-${timestampForFile(startedAt)}-payment-${paymentType}.json`);
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2), "utf8");

  console.log(JSON.stringify(report.result, null, 2));
  console.log("");
  console.log(`Report salvato in: ${reportPath}`);

  process.exit(report.result.success ? 0 : 2);
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
