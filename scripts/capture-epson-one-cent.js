// Emette un documento commerciale reale da EUR 0,01 e salva richiesta/risposta Epson.
// Usare solo su una stampante di test o quando si accetta l'emissione fiscale reale.
const fs = require("node:fs");
const path = require("node:path");
const { buildFiscalReceiptXml, printFiscalReceipt } = require("../EpsonFiscalClient.js");

const host = process.argv[2];
const port = Number(process.argv[3] || 80);
const devid = process.argv[4] || "local_printer";
const operator = process.argv[5] || "1";

if (!host) {
  console.error("Uso: node scripts/capture-epson-one-cent.js <ip> [porta] [devid] [operatore]");
  process.exit(1);
}

const receipt = {
  operator,
  items: [{
    description: "TEST SOFTWARE",
    quantity: "1",
    unitPrice: "0.01",
    department: "2"
  }],
  payment: {
    description: "CONTANTI",
    amount: "0.01",
    paymentType: "0",
    index: "1"
  }
};

const requestXml = buildFiscalReceiptXml(receipt);
const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
const outputDir = path.join(__dirname, "..", "fiscal-captures");
const outputPath = path.join(outputDir, `epson-one-cent-${timestamp}.json`);

(async () => {
  fs.mkdirSync(outputDir, { recursive: true });
  console.log(`Emissione documento reale da EUR 0,01 su ${host}:${port}...`);

  let result;
  try {
    result = await printFiscalReceipt(host, receipt, { port, devid, timeoutMs: 15000 });
  } catch (error) {
    const capture = {
      capturedAt: new Date().toISOString(),
      request: { host, port, devid, operator, receipt, requestXml },
      error: { name: error.name, message: error.message, stack: error.stack }
    };
    fs.writeFileSync(outputPath, JSON.stringify(capture, null, 2), "utf8");
    console.error(`Errore di comunicazione. Cattura salvata in ${outputPath}`);
    console.error(error.stack || error.message);
    process.exitCode = 2;
    return;
  }

  const capture = {
    capturedAt: new Date().toISOString(),
    request: { host, port, devid, operator, receipt, requestXml },
    response: {
      success: result.success,
      code: result.code,
      status: result.status,
      addInfo: result.addInfo,
      lines: result.lines,
      raw: result.raw
    }
  };
  fs.writeFileSync(outputPath, JSON.stringify(capture, null, 2), "utf8");
  console.log(`Risposta Epson catturata in ${outputPath}`);
  console.log(JSON.stringify(capture.response, null, 2));
  if (!result.success) process.exitCode = 3;
})();
