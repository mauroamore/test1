// Client per il protocollo "Fiscal ePOS-Print XML" delle stampanti fiscali Epson (FP-81II RT e
// famiglia), basato su "Epson ePOS Fiscal Print Solution Development Guide" Rev. T.
// Nessuna dipendenza esterna: solo fetch() nativo di Node, stesso stile di server.js.
//
// Endpoint: http://<ip-stampante>/cgi-bin/fpmate.cgi (porta web standard, 80 — NON 9100:
// verificato empiricamente il 2026-08-01, la porta 9100 citata in alcune schede tecniche di
// rivenditori si riferisce probabilmente alla stampa raw ESC/POS, non al servizio fpmate).
// Richiesta/risposta: SOAP 1.1 con corpo <printerCommand>...</printerCommand>.
//
// Nota importante: queryContentByDate/queryContentByNumbers (lettura libro giornale) richiedono
// che la stampante sia "loggata" prima (altrimenti risponde "Error 17 impossible now") — va
// chiamato login() con la password operatore configurata sulla stampante, non quella del portale
// Agenzia Entrate.

const DEFAULT_PORT = 80;
const DEFAULT_DEVID = "local_printer";
const DEFAULT_TIMEOUT_MS = 10000;
const DEFAULT_PC_POS_PORT = 9100;

function buildUrl(host, { port = DEFAULT_PORT, devid = DEFAULT_DEVID, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  return `http://${host}:${port}/cgi-bin/fpmate.cgi?devid=${encodeURIComponent(devid)}&timeout=${timeoutMs}`;
}

function escapeXml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatFiscalNumber(value) {
  return String(value).replace(".", ",");
}

function buildEnvelope(innerXml, wrapperTag = "printerCommand") {
  return `<?xml version="1.0" encoding="utf-8"?>\n` +
    `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">\n` +
    `  <s:Body>\n` +
    `    <${wrapperTag}>\n` +
    `      ${innerXml}\n` +
    `    </${wrapperTag}>\n` +
    `  </s:Body>\n` +
    `</s:Envelope>`;
}

function parseResponse(xmlText) {
  const attrs = {};
  const responseMatch = xmlText.match(/<response\b([^>]*)\/?>/i);
  if (responseMatch) {
    const attrRegex = /(\w+)="([^"]*)"/g;
    let m;
    while ((m = attrRegex.exec(responseMatch[1]))) attrs[m[1]] = m[2];
  }
  const lines = [];
  const lineRegex = /<lineNumber\d+>([\s\S]*?)<\/lineNumber\d+>/g;
  let lm;
  while ((lm = lineRegex.exec(xmlText))) lines.push(lm[1]);
  const addInfo = {};
  const addInfoMatch = xmlText.match(/<addInfo>([\s\S]*?)<\/addInfo>/i);
  if (addInfoMatch) {
    const tagRegex = /<([A-Za-z_][\w.-]*)>([\s\S]*?)<\/\1>/g;
    let tm;
    while ((tm = tagRegex.exec(addInfoMatch[1]))) {
      addInfo[tm[1]] = tm[2].trim();
    }
  }
  return {
    raw: xmlText,
    success: attrs.success === "true",
    code: attrs.code || "",
    status: attrs.status || "",
    lines,
    addInfo
  };
}

// Invia un comando grezzo (contenuto di <printerCommand>) e restituisce la risposta interpretata.
async function sendCommand(host, innerXml, options = {}) {
  const url = buildUrl(host, options);
  const body = buildEnvelope(innerXml);
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "text/xml; charset=utf-8" },
    body,
    signal: options.signal
  });
  const text = await response.text();
  return parseResponse(text);
}

function buildFiscalReceiptXml({ items, payment, operator = "1" }) {
  if (!Array.isArray(items) || items.length === 0) {
    throw new Error("printFiscalReceipt richiede almeno una riga in items");
  }
  if (!payment || payment.amount === undefined || payment.amount === null) {
    throw new Error("printFiscalReceipt richiede payment.amount");
  }

  const lines = [`<beginFiscalReceipt operator="${escapeXml(operator)}" />`];
  for (const item of items) {
    const { description, quantity = "1", unitPrice, department = "1", justification = "1" } = item;
    if (!description) throw new Error("Ogni item richiede description");
    if (unitPrice === undefined || unitPrice === null) throw new Error(`Item "${description}" senza unitPrice`);

    lines.push(
      `<printRecItem operator="${escapeXml(operator)}" description="${escapeXml(description)}" quantity="${escapeXml(formatFiscalNumber(quantity))}" ` +
      `unitPrice="${escapeXml(formatFiscalNumber(unitPrice))}" department="${escapeXml(department)}" justification="${escapeXml(justification)}" />`
    );
  }

  const { description: payDescription = "Contanti", amount, paymentType = "0", index = "1", justification = "1" } = payment;
  lines.push(
    `<printRecTotal operator="${escapeXml(operator)}" description="${escapeXml(payDescription)}" payment="${escapeXml(formatFiscalNumber(amount))}" ` +
    `paymentType="${escapeXml(paymentType)}" index="${escapeXml(index)}" justification="${escapeXml(justification)}" />`
  );
  lines.push(`<endFiscalReceipt operator="${escapeXml(operator)}" />`);

  return lines.join("\n      ");
}

function applyOneCentTestMode(receipt, { enabled = false, department = "1" } = {}) {
  if (!enabled) return receipt;
  const payment = receipt && receipt.payment ? receipt.payment : {};
  return {
    operator: receipt && receipt.operator ? receipt.operator : "1",
    items: [{
      description: "TEST SOFTWARE",
      quantity: "1",
      unitPrice: "0.01",
      department: String(department || "1")
    }],
    payment: {
      description: payment.description || "TEST",
      amount: "0.01",
      paymentType: payment.paymentType === undefined ? "0" : String(payment.paymentType),
      index: payment.index === undefined ? "1" : String(payment.index)
    }
  };
}

// Simulazione locale: mantiene lo stesso contratto della risposta della stampante
// senza effettuare chiamate di rete e senza produrre documenti fiscali reali.
let simulatedReceiptNumber = 0;
async function simulateFiscalReceipt({ items, payment, operator = "1" } = {}) {
  if (!Array.isArray(items) || items.length === 0) {
    throw new Error("simulateFiscalReceipt richiede almeno una riga in items");
  }
  if (!payment || payment.amount === undefined || payment.amount === null) {
    throw new Error("simulateFiscalReceipt richiede payment.amount");
  }

  const amount = Number(payment.amount);
  if (!Number.isFinite(amount)) throw new Error("Importo fiscale non valido");
  simulatedReceiptNumber += 1;

  return {
    success: true,
    simulated: true,
    operator: String(operator),
    code: "SIMULATED",
    status: "closed",
    receiptNumber: `SIM-${String(simulatedReceiptNumber).padStart(6, "0")}`,
    fiscalDate: new Date().toISOString().slice(0, 10),
    total: Number(amount.toFixed(2)),
    currency: "EUR",
    payment: { ...payment, amount: Number(amount.toFixed(2)) },
    items: items.map(item => ({
      description: String(item.description || ""),
      quantity: Number(item.quantity || 1),
      unitPrice: Number(item.unitPrice || 0)
    })),
    raw: "SIMULATED_FISCAL_RECEIPT"
  };
}

// Verifica di connettivita' innocua: non richiede login, nessun effetto collaterale.
// statusType: "0" = stato base, "1" = stato RT.
async function queryPrinterStatus(host, { operator = "", statusType = "0", ...options } = {}) {
  return sendCommand(host, `<queryPrinterStatus operator="${operator}" statusType="${escapeXml(statusType)}" />`, options);
}

// Login richiesto prima di queryContentByDate/queryContentByNumbers.
// Password = quella operatore configurata sulla stampante (non quella del portale AdE).
async function login(host, password, { operator = "1", ...options } = {}) {
  const data = ("02" + password).padEnd(100, " ").slice(0, 100);
  return sendCommand(host, `<directIO operator="${operator}" command="4038" data="${escapeXml(data)}" />`, options);
}

// Lettura libro giornale per intervallo di date.
// dataType: 0=Tutto, 1=Documenti commerciali (incl. resi/annulli), 2=Fatture, 3=Titoli di accesso.
async function queryContentByDate(host, { operator = "1", dataType = "0", fromDay, fromMonth, fromYear, toDay, toMonth, toYear, ...options } = {}) {
  const attrs = `operator="${operator}" dataType="${escapeXml(dataType)}" fromDay="${fromDay}" fromMonth="${fromMonth}" fromYear="${fromYear}" toDay="${toDay}" toMonth="${toMonth}" toYear="${toYear}"`;
  return sendCommand(host, `<queryContentByDate ${attrs} />`, options);
}

// Lettura libro giornale per intervallo di numeri documento in un giorno specifico.
async function queryContentByNumbers(host, { operator = "1", dataType = "0", day, month, year, fromNumber, toNumber, ...options } = {}) {
  const attrs = `operator="${operator}" dataType="${escapeXml(dataType)}" day="${day}" month="${month}" year="${year}" fromNumber="${fromNumber}" toNumber="${toNumber}"`;
  return sendCommand(host, `<queryContentByNumbers ${attrs} />`, options);
}

// Stampa un documento commerciale fiscale vero (permanente, entra nei corrispettivi del giorno).
// Nessun login richiesto per stampare (solo per le query del giornale).
// items: [{ description, quantity="1", unitPrice, department="1", justification="1" }]
// payment: { description="Contanti", amount, paymentType="0", index="1", justification="1" }
// paymentType: 0=Contante, 1=Assegno, 2=Carta di credito, 3=Ticket, 4=Credito, 5=Altro, 6=Bancomat
async function printFiscalReceipt(host, { items, payment, operator = "1" }, options = {}) {
  const url = buildUrl(host, options);
  const innerXml = buildFiscalReceiptXml({ items, payment, operator });
  const body = buildEnvelope(innerXml, "printerFiscalReceipt");
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "text/xml; charset=utf-8" },
    body,
    signal: options.signal
  });
  const text = await response.text();
  return parseResponse(text);
}

// Protocollo Epson FP legacy PC-POS: stampa di un documento non fiscale.
// Le righe del comando 064 sono esattamente 40 byte; il dispositivo aggiunge
// autonomamente le diciture NON FISCALE in testa e in coda.
function buildPcPosFrame(applicationPdu, counter = "00") {
  const cnt = String(counter).padStart(2, "0").slice(-2);
  const payload = Buffer.from(`${cnt}E${applicationPdu}`, "latin1");
  const checksum = String([...payload].reduce((sum, byte) => sum + byte, 0) % 100).padStart(2, "0");
  return Buffer.concat([Buffer.from([0x02]), payload, Buffer.from(checksum, "ascii"), Buffer.from([0x03])]);
}

function readPcPosResponse(buffer) {
  const start = buffer.indexOf(0x02);
  const end = buffer.indexOf(0x03, start + 1);
  if (start < 0 || end < 0) return null;
  const frame = buffer.subarray(start, end + 1);
  return {
    raw: frame,
    counter: frame.subarray(1, 3).toString("ascii"),
    identifier: frame.subarray(3, 4).toString("latin1"),
    applicationPdu: frame.subarray(4, -3).toString("latin1"),
    checksum: frame.subarray(-3, -1).toString("ascii")
  };
}

function sendPcPosFrame(socket, frame, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  return new Promise((resolve, reject) => {
    let received = Buffer.alloc(0);
    let acknowledged = false;
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error(`Timeout PC-POS Epson${acknowledged ? " dopo ACK" : " in attesa di ACK"}`));
    }, timeoutMs);
    const finish = (error, result) => {
      clearTimeout(timer);
      socket.off("data", onData);
      error ? reject(error) : resolve(result);
    };
    const onData = chunk => {
      received = Buffer.concat([received, chunk]);
      if (received.includes(0x06)) acknowledged = true;
      const response = readPcPosResponse(received);
      if (response) finish(null, { acknowledged, response });
    };
    socket.on("data", onData);
    socket.once("error", error => finish(error));
    socket.write(frame);
  });
}

function printNonFiscalReceipt(host, { lines, operator = "1" } = {}, { port = DEFAULT_PC_POS_PORT, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  if (!host) throw new Error("printNonFiscalReceipt richiede host");
  if (!Array.isArray(lines)) throw new Error("printNonFiscalReceipt richiede lines");
  const op = String(operator).padStart(2, "0").slice(-2);
  const normalizedLines = lines.map(line => Buffer.from(String(line ?? ""), "latin1").subarray(0, 40).toString("latin1"));
  return new Promise((resolve, reject) => {
    const net = require("net");
    const socket = net.createConnection({ host, port });
    let counter = 0;
    const send = async () => {
      try {
        const responses = [];
        const begin = await sendPcPosFrame(socket, buildPcPosFrame(`1063${op}`, counter++), { timeoutMs });
        responses.push(begin);
        for (const line of normalizedLines) {
          responses.push(await sendPcPosFrame(socket, buildPcPosFrame(`1064${op}1${line.padEnd(40, " ")}`, counter++), { timeoutMs }));
        }
        responses.push(await sendPcPosFrame(socket, buildPcPosFrame(`1065${op}`, counter++), { timeoutMs }));
        socket.end();
        resolve({ success: true, protocol: "Epson PC-POS", host, port, lines: normalizedLines, responses });
      } catch (error) {
        socket.destroy();
        reject(error);
      }
    };
    socket.once("connect", send);
    socket.once("error", reject);
  });
}

module.exports = {
  sendCommand,
  parseResponse,
  buildFiscalReceiptXml,
  applyOneCentTestMode,
  simulateFiscalReceipt,
  queryPrinterStatus,
  login,
  queryContentByDate,
  queryContentByNumbers,
  printFiscalReceipt
  ,buildPcPosFrame,
  printNonFiscalReceipt
};

// Test manuale da riga di comando:
//   node EpsonFiscalClient.js <ip> [password] [devid]
// Senza password: solo queryPrinterStatus (nessun login, nessun effetto collaterale).
// Con password: login + lettura libro giornale di oggi.
if (require.main === module) {
  (async () => {
    const host = process.argv[2];
    const password = process.argv[3];
    const devid = process.argv[4] || DEFAULT_DEVID;
    if (!host) {
      console.error("Uso: node EpsonFiscalClient.js <ip> [password] [devid]");
      process.exit(1);
    }

    console.log(`--- queryPrinterStatus (statusType RT) su ${host} ---`);
    try {
      const status = await queryPrinterStatus(host, { statusType: "1", devid });
      console.log(status);
    } catch (err) {
      console.error("Errore queryPrinterStatus:", err.message);
      process.exit(1);
    }

    if (!password) {
      console.log("\nNessuna password fornita: mi fermo qui (niente login/query giornale).");
      return;
    }

    console.log("\n--- login ---");
    const loginResult = await login(host, password, { devid });
    console.log(loginResult);
    if (!loginResult.success) {
      console.error("Login fallito, mi fermo qui.");
      process.exit(1);
    }

    const today = new Date();
    const day = today.getDate();
    const month = today.getMonth() + 1;
    const year = today.getFullYear();

    console.log("\n--- queryContentByDate (oggi) ---");
    const journal = await queryContentByDate(host, {
      fromDay: day, fromMonth: month, fromYear: year,
      toDay: day, toMonth: month, toYear: year,
      devid
    });
    console.log(journal);
  })().catch(err => {
    console.error("Errore:", err);
    process.exit(1);
  });
}
