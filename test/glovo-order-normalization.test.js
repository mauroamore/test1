const test = require("node:test");
const assert = require("node:assert/strict");
const { normalizeGlovoOrder } = require("../src/glovo-order-normalization");

const samplePayload = {
  source: "glovo",
  orderId: "101793892505",
  orderCode: "96",
  state: "PREORDER_ACCEPTED",
  pickupAt: "2026-10-05T16:19:24.878Z",
  customerNote: "Posate richieste",
  items: [
    { dishNumber: null, dishName: "Riso bianco", originalName: "Riso bianco", quantity: 2, variations: [], note: null },
    { dishNumber: "60", dishName: "Keng Ped Kai (Muu, Nua)", originalName: "60 Keng Ped Kai (Muu, Nua)", quantity: 1, variations: [{ quantity: 1, name: "Vitello" }] },
    { dishNumber: "04", dishName: "Kai Sate - spiedini di pollo", originalName: "04 Kai Sate - spiedini di pollo", quantity: 1, variations: [] },
    { dishNumber: "74", dishName: "Kai Pad Pongkari", originalName: "74 Kai Pad Pongkari", quantity: 1, variations: [] }
  ]
};

test("uses the restaurant menu to price Glovo's name-and-quantity payload", () => {
  const catalog = new Map([
    ["78", { id: 78, name: "100 Jasmine White Rice", price: 2, category: "Extra Rice" }],
    ["18", { id: 18, name: "60 Keng Ped Kai (Muu, Nua)", price: 14, category: "Curry" }],
    ["33", { id: 33, name: "4 Kai (Muu) Sate", price: 7, category: "Starters" }],
    ["76", { id: 76, name: "74 Kai Pad Pongkari", price: 14, category: "Special Bangkok" }]
  ]);

  const order = normalizeGlovoOrder(samplePayload, catalog);

  assert.equal(order.id, "glovo-101793892505");
  assert.equal(order.collectionCode, "96");
  assert.equal(order.notes, "Posate richieste");
  assert.equal(order.total, 39);
  assert.deepEqual(order.items.map(item => item.price), [2, 14, 7, 14]);
  assert.deepEqual(order.items.map(item => item.qty), [2, 1, 1, 1]);
  assert.equal(order.items[1].lineNote, "Vitello");
  assert.equal(order.items[1].category, "Curry");
});

test("matches a catalog item by normalized name when the dish code is absent", () => {
  const order = normalizeGlovoOrder({
    orderId: "abc",
    items: [{ dishName: "Riso bianco", quantity: 1 }]
  }, new Map([["rice", { id: "rice", name: "  RISO   BIANCO ", price: 3.5, category: "Contorni" }]]));

  assert.equal(order.items[0].id, "rice");
  assert.equal(order.total, 3.5);
});

test("matches zero-padded Glovo dish numbers to the menu's numeric code", () => {
  const order = normalizeGlovoOrder({
    orderId: "abc",
    items: [{ dishNumber: "04", dishName: "Kai Sate - spiedini di pollo", quantity: 1 }]
  }, new Map([["33", { id: 33, name: "4 Kai (Muu) Sate", price: 7, category: "Starters" }]]));

  assert.equal(order.items[0].id, 33);
  assert.equal(order.items[0].price, 7);
});

test("uses the supplied Glovo item name without prepending its dish code", () => {
  const order = normalizeGlovoOrder({
    orderId: "abc",
    items: [{ dishNumber: "48", dishName: "48 Keng Kariii kai", quantity: 1 }]
  }, new Map([[
    "48",
    { id: 48, name: "48 Keng Kariii kai", price: 14, category: "Curry" }
  ]]));

  assert.equal(order.items[0].name, "48 Keng Kariii kai");
});

test("accepts Glovo's nested pricing payload and final order total", () => {
  const order = normalizeGlovoOrder({
    order_id: "uuid",
    items: [{ name: "Pad Thai", pricing: { unit_price: 10, total_price: 20, quantity: 2 } }],
    payment: { sub_total: 20, order_total: 18 }
  });

  assert.equal(order.items[0].price, 10);
  assert.equal(order.items[0].qty, 2);
  assert.equal(order.total, 18);
});

test("rejects an item when neither the payload nor menu can provide its price", () => {
  assert.throws(
    () => normalizeGlovoOrder({ orderId: "abc", items: [{ dishName: "Prodotto sconosciuto", quantity: 1 }] }, new Map()),
    /Prezzo non trovato nel menu Glovo: Prodotto sconosciuto/
  );
});
