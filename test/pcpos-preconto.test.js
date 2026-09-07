const test = require("node:test");
const assert = require("node:assert/strict");
const { buildPcPosPrecontoLines } = require("../src/pcpos-preconto.js");

test("preconto PC-POS include coperti, totali e sconto", () => {
  const lines = buildPcPosPrecontoLines({
    id: 12,
    covers: 2,
    items: [{ name: "Thai Tea", qty: 1, price: 2.5 }],
    discount: 1
  }, { coverCharge: 2 });
  assert.equal(lines[0].trim(), "Thai Princess");
  assert.ok(lines.some(line => line.includes("2 x Coperto")));
  assert.ok(lines.some(line => line.includes("Totale")));
  assert.ok(lines.some(line => line.includes("Sconto")));
  assert.ok(lines.some(line => line.includes("Nuovo Totale")));
  assert.ok(lines.every(line => line.length <= 40));
});
