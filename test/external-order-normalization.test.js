const test = require("node:test");
const assert = require("node:assert/strict");
const {
  normalizeHubRiseOrder,
  applyHubRiseStatusUpdate,
  migrateLocalOrderToHubRiseShape
} = require("../src/external-order-normalization");

test("normalizes a HubRise order into the local kitchen line format", () => {
  const order = normalizeHubRiseOrder({
    external_order_id: "abc",
    status: "new",
    service_type: "delivery",
    items: [{ id: "item-1", product_name: "Pad Thai", price: "12.50", quantity: "2", options: [{ name: "Piccante" }] }]
  });

  assert.equal(order.id, "hubrise-abc");
  assert.equal(order.items[0].externalItemId, "item-1");
  assert.equal(order.items[0].name, "Pad Thai");
  assert.equal(order.items[0].qty, 2);
  assert.equal(order.items[0].price, 12.5);
  assert.equal(order.items[0].lineNote, "Piccante");
});

test("applies a HubRise status update without replacing the local comanda", () => {
  const existing = normalizeHubRiseOrder({
    external_order_id: "abc",
    status: "received",
    items: [{ id: "item-1", product_name: "Pad Thai", quantity: 2 }]
  });
  existing.items[0].tho.sent_quantity = 1;
  existing.items[0].tho.course = 2;
  existing.tho.kitchen_status = "in_preparation";

  const updated = applyHubRiseStatusUpdate(existing, {
    status: "in_delivery",
    items: [{ id: "item-1", product_name: "CHANGED", quantity: 99 }]
  });

  assert.equal(updated.status, "in_delivery");
  assert.equal(updated.items[0].name, "Pad Thai");
  assert.equal(updated.items[0].qty, 2);
  assert.equal(updated.items[0].tho.sent_quantity, 1);
  assert.equal(updated.items[0].tho.course, 2);
  assert.equal(updated.tho.kitchen_status, "in_preparation");
});

test("rejects a HubRise order without an id", () => {
  assert.throws(() => normalizeHubRiseOrder({ items: [] }), /senza identificativo/);
});

test("migrates a local table order without changing its source object", () => {
  const local = {
    id: "12",
    occupied: true,
    kitchenClosed: false,
    lines: [{ key: "line-1", name: "Pad Thai", qty: 2, price: 12.5, sentQty: 1, course: 2 }]
  };
  const migrated = migrateLocalOrderToHubRiseShape(local);

  assert.equal(local.items, undefined);
  assert.equal(migrated.items[0].product_name, "Pad Thai");
  assert.equal(migrated.items[0].quantity, 2);
  assert.equal(migrated.items[0].tho.sent_quantity, 1);
  assert.equal(migrated.items[0].tho.course, 2);
  assert.equal(migrated.tho.table_id, "12");
  assert.equal(Object.prototype.hasOwnProperty.call(migrated, "items"), true);
  assert.equal(Object.prototype.hasOwnProperty.call(migrated, "lines"), false);
});
