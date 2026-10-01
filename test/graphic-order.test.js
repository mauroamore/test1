const test = require("node:test");
const assert = require("node:assert/strict");
const { buildGraphicOrder } = require("../src/graphic-preconto");

test("graphic order renders at configured paper width and includes a raster body", () => {
  const canvas = buildGraphicOrder({
    id: 11,
    tableName: "Tavolo 11",
    items: [
      { qty: 2, name: "Pad Thai", usesTurns: true, course: 0, variations: "Poco piccante" },
      { qty: 1, name: "Thai Tea", usesTurns: false, course: 0 }
    ]
  }, { width: 58, fontSize: 1 });

  assert.equal(canvas.width, 384);
  assert.ok(canvas.height > 100);
  const pixels = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
  assert.ok(pixels.some((value, index) => index % 4 === 0 && value < 128));
});

test("graphic order respects configured paper and character scaling", () => {
  const order = { id: 4, items: [{ qty: 1, name: "Tom Yum", usesTurns: true, course: 1 }] };
  const normal = buildGraphicOrder(order, { width: 80, fontSize: 1 });
  const enlarged = buildGraphicOrder(order, { width: 80, fontSize: 2 });

  assert.equal(normal.width, 512);
  assert.equal(enlarged.width, 512);
  assert.ok(enlarged.height > normal.height);
});

test("graphic order prints takeaway name and pickup time content", () => {
  const takeaway = buildGraphicOrder({
    id: "pickup-1",
    source: "manual",
    customerName: "Mauro",
    pickupTime: "19:30",
    items: [{ qty: 1, name: "Som Tam", variations: "Senza arachidi" }]
  }, { width: 58, fontSize: 1 });
  const immediate = buildGraphicOrder({ source: "manual", items: [] }, { width: 58, fontSize: 1 });

  assert.ok(takeaway.height > immediate.height);
});
