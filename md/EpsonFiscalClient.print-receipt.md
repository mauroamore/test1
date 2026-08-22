# Modifica da fare: aggiungere la stampa scontrino a `EpsonFiscalClient.js`

## Perché in un file separato

Questa funzione, se eseguita, **emette un documento fiscale reale e permanente** (entra nei
corrispettivi del giorno, registrato nella memoria sigillata del registratore telematico). Per
questo motivo non l'ho scritta/eseguita io direttamente nel modulo — va aggiunta ed eseguita da chi
si assume la responsabilità dell'azione (voi, o chi preferite).

Il resto di `EpsonFiscalClient.js` (status, login, lettura giornale) non ha questo problema — quelle
funzioni sono già presenti e funzionanti nel file.

## Premessa tecnica

A differenza di `queryPrinterStatus`/`login`/`queryContentByDate` (che usano il wrapper
`<printerCommand>`), la stampa di uno scontrino usa un wrapper diverso: **`<printerFiscalReceipt>`**,
contenente in sequenza più comandi in un'unica richiesta SOAP.

Nessun login è richiesto per stampare (solo le query del giornale lo richiedono).

## Codice da aggiungere

Nel file `EpsonFiscalClient.js`, prima della riga `module.exports = {...}`, aggiungere:

```javascript
// Stampa un documento commerciale fiscale vero (permanente, entra nei corrispettivi del giorno).
// Nessun login richiesto per stampare (solo per le query del giornale).
// items: [{ description, quantity="1", unitPrice, department="1", justification="" }]
// payment: { description="Contanti", amount, paymentType="0", index="1" }
// paymentType: 0=Contante, 1=Assegno, 2=Carta di credito, 3=Ticket, 4=Credito, 5=Altro, 6=Bancomat
async function printFiscalReceipt(host, { items, payment, operator = "1" }, options = {}) {
  const lines = [`<beginFiscalReceipt operator="${operator}" />`];
  for (const item of items) {
    const { description, quantity = "1", unitPrice, department = "1", justification = "" } = item;
    lines.push(
      `<printRecItem operator="${operator}" description="${escapeXml(description)}" quantity="${quantity}" ` +
      `unitPrice="${unitPrice}" department="${escapeXml(department)}" justification="${escapeXml(justification)}" />`
    );
  }
  const { description: payDescription = "Contanti", amount, paymentType = "0", index = "1" } = payment;
  lines.push(
    `<printRecTotal operator="${operator}" description="${escapeXml(payDescription)}" payment="${amount}" ` +
    `paymentType="${paymentType}" index="${index}" />`
  );
  lines.push(`<endFiscalReceipt operator="${operator}" />`);

  const url = buildUrl(host, options);
  const body = buildEnvelope(lines.join("\n      "), "printerFiscalReceipt");
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "text/xml; charset=utf-8" },
    body
  });
  const text = await response.text();
  return parseResponse(text);
}
```

E aggiungere `printFiscalReceipt` all'oggetto esportato in fondo al file:

```javascript
module.exports = {
  sendCommand,
  queryPrinterStatus,
  login,
  queryContentByDate,
  queryContentByNumbers,
  printFiscalReceipt   // <-- aggiungere questa riga
};
```

## Serve anche modificare `buildEnvelope`

La funzione `buildEnvelope` attuale ha il wrapper `<printerCommand>` fisso. Va reso parametrico:

**Prima:**
```javascript
function buildEnvelope(innerXml) {
  return `<?xml version="1.0" encoding="utf-8"?>\n` +
    `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">\n` +
    `  <s:Body>\n` +
    `    <printerCommand>\n` +
    `      ${innerXml}\n` +
    `    </printerCommand>\n` +
    `  </s:Body>\n` +
    `</s:Envelope>`;
}
```

**Dopo:**
```javascript
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
```

(Il default `"printerCommand"` mantiene invariato il comportamento delle funzioni esistenti che non
passano un secondo argomento.)

## Come usarla (esempio, da eseguire voi)

```javascript
const epson = require("./EpsonFiscalClient.js");

epson.printFiscalReceipt("192.168.1.201", {
  items: [
    { description: "Test scambio importo", quantity: "1", unitPrice: "0.01", department: "1" }
  ],
  payment: { description: "Contanti", amount: "0.01", paymentType: "0" }
}).then(console.log);
```

## Cosa verificare prima di lanciarlo per davvero

- **`department`**: il numero di reparto (1, 2, 3...) deve corrispondere a un reparto/aliquota IVA
  realmente configurato sulla stampante — se non siete sicuri di quale numero usare per un articolo
  "di prova", chiedetelo a chi ha configurato i reparti (installatore), altrimenti rischiate di
  stampare con un'aliquota IVA sbagliata.
- L'importo (`unitPrice`/`payment.amount`) va passato come stringa con il punto decimale (es. `"0.01"`).
- Il documento stampato **entra nei corrispettivi del giorno** — se è solo un test, tenetelo a mente
  per la chiusura di fine giornata (o annullatelo con la procedura VOID già documentata in
  precedenza, se preferite non lasciarlo nei totali).
