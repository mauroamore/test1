const test = require("node:test");
const assert = require("node:assert/strict");
const epson = require("../EpsonFiscalClient.js");

test("Epson genera XML fiscale con contenuto escapato", () => {
  const xml = epson.buildFiscalReceiptXml({
    items: [{ description: "A&B <test>", quantity: "1", unitPrice: "2.50", department: "2" }],
    payment: { description: "Contanti", amount: "2.50", paymentType: "0", index: "1" }
  });
  assert.match(xml, /A&amp;B &lt;test&gt;/);
  assert.match(xml, /beginFiscalReceipt/);
  assert.match(xml, /2,50/);
});

test("Epson costruisce il percorso della copia elettronica usando il documento", () => {
  const url = epson.buildEReceiptPdfUrl("192.168.1.201", {
    date: "05/09/26", time: "134032", documentNumber: "12", zReportNumber: "1345", printerSerialNumber: "99IEB045200"
  });
  assert.match(url, /192\.168\.1\.201/);
  assert.match(url, /20260905/);
  assert.match(url, /N0012/);
  assert.match(url, /Z1345/);
});

test("Epson prepara l'XML di annullamento con i riferimenti fiscali", () => {
  const xml = epson.buildVoidFiscalReceiptXml({
    zReportNumber: "1345", documentNumber: "12", fiscalReceiptDate: "05/09/2026", rtSerialNumber: "99IEB045200"
  });
  assert.match(xml, /1345/);
  assert.match(xml, /12/);
  assert.match(xml, /05092026/);
  assert.match(xml, /99IEB045200/);
});
