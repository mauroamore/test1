const test = require("node:test");
const assert = require("node:assert/strict");
const { normalizeGlovoOrder, normalizeDeliverooOrder, normalizeJustEatOrder } = require("../src/glovo-order-normalization");

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

test("normalizes Deliveroo order numbers, euro-cent prices, modifiers, and prepare time", () => {
  const payload = {
    id: "c8a585c6-e0ad-3a1c-a81d-6012142bdee7",
    order_number: "5957",
    status: "accepted",
    amount: { fractional: 3400, currency_code: "EUR" },
    timeline: { prepare_for: "2026-10-02T19:50:39+02:00" },
    items: [
      {
        name: "11 Pad Thai Phak Sod",
        quantity: 1,
        unit_price: { fractional: 1200 },
        total_price: { fractional: 1200 },
        modifiers: []
      },
      {
        name: "7 Phak Kung Tod",
        quantity: 1,
        unit_price: { fractional: 800 },
        total_price: { fractional: 800 },
        modifiers: [{ name: "Piccante" }]
      },
      {
        name: "16 Pad Si Yuu",
        quantity: 1,
        unit_price: { fractional: 1400 },
        total_price: { fractional: 1400 },
        modifiers: []
      }
    ]
  };
  const catalog = new Map([
    ["11", { id: 11, name: "11 Pad Thai Phak Sod", price: 12, category: "Noodles" }],
    ["7", { id: 7, name: "7 Phak Kung Tod", price: 8, category: "Antipasti" }],
    ["16", { id: 16, name: "16 Pad Si Yuu", price: 14, category: "Noodles" }]
  ]);

  const order = normalizeDeliverooOrder(payload, catalog, {
    sourceOrderId: payload.id,
    orderCode: payload.order_number,
    totalCents: payload.amount.fractional,
    currency: payload.amount.currency_code,
    prepareFor: payload.timeline.prepare_for,
    items: payload.items.map(item => ({
      sourceName: item.name,
      itemCode: item.name.split(" ")[0],
      itemName: item.name.split(" ").slice(1).join(" "),
      quantity: item.quantity,
      unitPriceCents: item.unit_price.fractional,
      totalPriceCents: item.total_price.fractional,
      variations: item.modifiers
    }))
  });

  assert.equal(order.id, `deliveroo-${payload.id}`);
  assert.equal(order.source, "deliveroo");
  assert.equal(order.collectionCode, "5957");
  assert.equal(order.total, 34);
  assert.equal(order.pickupTime, payload.timeline.prepare_for);
  assert.deepEqual(order.items.map(item => item.price), [12, 8, 14]);
  assert.deepEqual(order.items.map(item => item.id), [11, 7, 16]);
  assert.equal(order.items[0].name, "11 Pad Thai Phak Sod");
  assert.equal(order.items[1].lineNote, "Piccante");
});

test("uses Deliveroo's captured normalized prices when raw prices are absent", () => {
  const order = normalizeDeliverooOrder({
    id: "deliveroo-normalized-only",
    order_number: "6001",
    amount: { fractional: 900, currency_code: "EUR" },
    items: [{ name: "11 Pad Thai Phak Sod", quantity: 1 }]
  }, new Map(), {
    items: [{ sourceName: "11 Pad Thai Phak Sod", itemCode: "11", itemName: "Pad Thai Phak Sod", quantity: 1, unitPriceCents: 900, totalPriceCents: 900 }]
  });

  assert.equal(order.collectionCode, "6001");
  assert.equal(order.total, 9);
  assert.equal(order.items[0].price, 9);
});

test("normalizes the real Deliveroo categories payload using restaurant subtotal and ASAP time", () => {
  const payload = {
    id: "51215730904",
    drn_id: "d56ef371-cc32-40c2-a60a-bd0f875f30b9",
    status: "accepted",
    order_number: "0904",
    subtotal: 21,
    subtotal_after_substitutions: 21,
    total: 26.01,
    currency_code: "EUR",
    ready_by: "2026-10-06T17:37:49Z",
    placed_at: "2026-10-06T17:21:46Z",
    asap: true,
    allergy_note: "NO POSATE",
    delivery_note: "Hôtel Agathae",
    cutlery_requested: false,
    categories: [
      { name: "Antipasti", order_items: [{ id: 52790241647, quantity: 1, name: "3 Phopie Sod", unit_price: 7, total_unit_price: 7 }] },
      { name: "Noodles", order_items: [{ id: 52790241648, quantity: 1, name: "16 Pad Si Yuu", unit_price: 14, total_unit_price: 14 }] }
    ]
  };
  const catalog = new Map([
    ["3", { id: 3, name: "3 Phopie Sod", price: 7, category: "Antipasti" }],
    ["16", { id: 16, name: "16 Pad Si Yuu", price: 14, category: "Noodles" }]
  ]);

  const normalized = normalizeDeliverooOrder(payload, catalog);

  assert.equal(normalized.externalOrderId, "51215730904");
  assert.equal(normalized.collectionCode, "0904");
  assert.equal(normalized.total, 21);
  assert.equal(normalized.currency, "EUR");
  assert.equal(normalized.pickupTime, "Subito");
  assert.deepEqual(normalized.items.map(item => item.name), ["3 Phopie Sod", "16 Pad Si Yuu"]);
  assert.deepEqual(normalized.items.map(item => item.price), [7, 14]);
  assert.deepEqual(normalized.items.map(item => item.category), ["Antipasti", "Noodles"]);
  assert.match(normalized.notes, /NO POSATE/);
  assert.match(normalized.notes, /Hôtel Agathae/);
});

test("keeps Just Eat delivery fees outside kitchen items and stores them for checkout", () => {
  const order = normalizeJustEatOrder({
    id: "justeat-fee-test",
    friendlyId: "456",
    serviceType: "delivery",
    orderPrice: 1200,
    orderItems: [{ itemId: "pad-thai", name: "11 Pad Thai", quantity: 1, unitPrice: 1200 }]
  }, new Map([["pad-thai", { id: "pad-thai", name: "11 Pad Thai", price: 12 }]]), {
    feesCents: 250
  });

  assert.equal(order.fees, 2.5);
  assert.equal(order.total, 12);
  assert.equal(order.items.length, 1);
  assert.equal(order.items[0].price, 12);
});
