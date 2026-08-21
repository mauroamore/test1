function parseHubRiseAmount(value) {
  if (typeof value === "number") return value;
  const match = String(value ?? "").replace(",", ".").match(/-?\d+(?:\.\d+)?/);
  return match ? Number(match[0]) : 0;
}

function hubRiseOrderId(order) {
  const id = order && (order.external_order_id || order.id || order.order_id);
  return id ? `hubrise-${id}` : null;
}

function hubRiseLine(item, orderId, index) {
  const externalId = item && (item.id || item.external_item_id || item.ref);
  const options = Array.isArray(item && item.options) ? item.options : [];
  return {
    key: externalId ? `hubrise-${orderId}-${externalId}` : `hubrise-${orderId}-${index}`,
    externalItemId: externalId || null,
    name: item.name || item.product_name || "Articolo HubRise",
    category: item.category || "",
    price: parseHubRiseAmount(item.unit_price ?? item.price),
    qty: Number(item.quantity) || 1,
    tho: { sent_quantity: 0, course: 1, no_turns: true, kitchen_status: null },
    minusVariations: [],
    plusVariations: [],
    lineNote: options.map(option => option.name).filter(Boolean).join(", ")
  };
}

function normalizeHubRiseOrder(order) {
  const id = hubRiseOrderId(order);
  if (!id) throw new Error("Ordine HubRise senza identificativo");
  const externalId = String(order.external_order_id || order.id || order.order_id);
  const items = Array.isArray(order.items) ? order.items : [];
  return {
    id,
    source: "hubrise",
    externalOrderId: externalId,
    customerName: [order.customer?.first_name, order.customer?.last_name].filter(Boolean).join(" ") || "Ordine HubRise",
    serviceType: order.service_type || order.serviceType || "delivery",
    status: order.status || "new",
    total: parseHubRiseAmount(order.total),
    currency: order.currency || "EUR",
    collectionCode: order.collection_code || null,
    channel: order.channel || "HubRise",
    items,
    receivedAt: order.received_at || order.created_at || null,
    items: items.map((item, index) => hubRiseLine(item, externalId, index)),
    selectedCourse: 1,
    activeCourse: 1,
    tho: { kitchen_status: "new", table_id: null, table_status: null, kitchen_closed: false }
  };
}

function applyHubRiseStatusUpdate(existing, incoming) {
  if (!existing || existing.source !== "hubrise") return existing;
  return {
    ...existing,
    status: incoming.status || existing.status,
    serviceType: incoming.service_type || incoming.serviceType || existing.serviceType,
    collectionCode: incoming.collection_code ?? existing.collectionCode,
    channel: incoming.channel || existing.channel,
    receivedAt: incoming.received_at || incoming.created_at || existing.receivedAt
  };
}

function migrateLocalOrderToHubRiseShape(order) {
  if (!order) return order;
  if (Array.isArray(order.items)) return order;
  const lines = Array.isArray(order.lines) ? order.lines : [];
  const migrated = {
    ...order,
    items: lines.map(line => ({
      id: line.externalItemId || line.key,
      product_name: line.name || "",
      price: line.price,
      quantity: line.qty,
      options: [],
      tho: {
        sent_quantity: Number(line.sentQty || 0),
        course: Number(line.course || 1),
        kitchen_status: line.kitchenStatus || null,
        note: line.lineNote || ""
      }
    })),
    tho: {
      ...(order.tho || {}),
      kitchen_closed: Boolean(order.kitchenClosed),
      table_id: order.id && !order.source ? String(order.id) : null
    }
  };
  delete migrated.lines;
  return migrated;
}

function migrateStateToHubRiseShape(state) {
  if (!state || typeof state !== "object") return state;
  for (const key of ["tables", "deliveryOrders"]) {
    if (Array.isArray(state[key])) state[key] = state[key].map(migrateLocalOrderToHubRiseShape);
  }
  return state;
}

module.exports = { normalizeHubRiseOrder, applyHubRiseStatusUpdate, migrateLocalOrderToHubRiseShape, migrateStateToHubRiseShape };
