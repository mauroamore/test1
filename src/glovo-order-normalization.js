function firstFiniteNumber(...values) {
  for (const value of values) {
    if (value === null || value === undefined || value === "") continue;
    const parsed = typeof value === "string"
      ? Number(value.trim().replace(/\s*(EUR|€)\s*$/i, "").replace(",", "."))
      : Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function normalizeMenuName(value) {
  return String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/^\s*\d{1,3}\s*[-.:)]?\s*/, "")
    .toLocaleLowerCase("it")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

function findCatalogItem(item, catalog) {
  if (!(catalog instanceof Map)) return null;
  const catalogId = String(item.catalogItemId || item.menuItemId || item.id || "").trim();
  if (catalogId && catalog.has(catalogId)) return catalog.get(catalogId);
  const itemCode = String(item.dishNumber || "").trim();
  const numericItemCode = Number.parseInt(itemCode, 10);
  if (Number.isFinite(numericItemCode)) {
    const codeMatches = [...catalog.values()].filter(candidate => {
      const catalogCode = String(candidate.name || "").match(/^\s*(\d{1,3})\b/);
      return catalogCode && Number.parseInt(catalogCode[1], 10) === numericItemCode;
    });
    if (codeMatches.length === 1) return codeMatches[0];
    if (codeMatches.length > 1) throw new Error(`Codice piatto Glovo ambiguo nel menu: ${itemCode}`);
  }

  const names = [item.dishName, item.name, item.product_name, item.originalName]
    .map(normalizeMenuName)
    .filter(Boolean);
  const aliases = new Map([
    ["riso bianco", ["jasmine white rice"]],
    ["riso bianco jasmine", ["jasmine white rice"]]
  ]);
  const acceptedNames = new Set(names);
  for (const name of names) {
    for (const alias of aliases.get(name) || []) acceptedNames.add(alias);
  }
  const matches = [];
  for (const candidate of catalog.values()) {
    if (acceptedNames.has(normalizeMenuName(candidate.name))) matches.push(candidate);
  }
  if (matches.length > 1) {
    const name = item.dishName || item.name || item.product_name || item.originalName;
    throw new Error(`Articolo Glovo ambiguo nel menu: ${name}`);
  }
  return matches[0] || null;
}

function normalizeGlovoOrder(order, catalog) {
  const externalId = String(order.externalId || order.external_order_id || order.orderId || order.order_id || order.id || "");
  if (!externalId) throw new Error("Ordine Glovo senza identificativo");

  const lines = (Array.isArray(order.items) ? order.items : []).map((item, index) => {
    const pricing = item.pricing && typeof item.pricing === "object" ? item.pricing : {};
    const originalPricing = item.original_pricing && typeof item.original_pricing === "object" ? item.original_pricing : {};
    const quantity = firstFiniteNumber(item.quantity, pricing.quantity, item.amount, item.qty, originalPricing.quantity, 1) || 1;
    const lineTotal = firstFiniteNumber(pricing.total_price, item.total_price, item.subtotal, item.sub_total);
    const catalogItem = findCatalogItem(item, catalog);
    let unitPrice = firstFiniteNumber(item.price, item.unit_price, item.unitPrice, pricing.unit_price, originalPricing.unit_price, catalogItem && catalogItem.price);
    if (unitPrice === null && lineTotal !== null && quantity !== 0) unitPrice = lineTotal / quantity;
    if (unitPrice === null) {
      const name = item.dishName || item.name || item.product_name || item.originalName || item.dishNumber || "articolo senza nome";
      throw new Error(`Prezzo non trovato nel menu Glovo: ${name}`);
    }

    const originalName = String(item.originalName || item.name || item.product_name || item.dishName || "Articolo Glovo");
    const dishNumber = item.dishNumber || (originalName.match(/^\s*(\d{1,3})\s+(.+)$/) || [])[1] || null;
    const name = item.originalName || (dishNumber ? `${dishNumber} ${item.dishName || originalName}` : originalName);
    const notes = [item.comment, item.note, item.specialInstructions, item.instructions]
      .filter(value => typeof value === "string" && value.trim());
    const modifiers = Array.isArray(item.variations) ? item.variations
      : Array.isArray(item.modifiers) ? item.modifiers
        : Array.isArray(item.options) ? item.options : [];
    const variations = modifiers.map(modifier => modifier && (modifier.name || modifier.option_name)).filter(Boolean);
    return {
      key: `glovo-${externalId}-${index}`,
      id: catalogItem ? catalogItem.id : dishNumber || item.sku || item.id || `glovo-item-${index}`,
      name,
      category: catalogItem && catalogItem.category || "Glovo",
      price: Number(unitPrice.toFixed(4)),
      originalPrice: Number(unitPrice.toFixed(4)),
      qty: quantity,
      sentQty: 0,
      course: 1,
      noTurns: true,
      kitchenStatus: undefined,
      minusVariations: [],
      plusVariations: [],
      lineNote: [...variations, ...notes].join(", ")
    };
  });

  const payment = order.payment && typeof order.payment === "object" ? order.payment : {};
  const lineTotals = (Array.isArray(order.items) ? order.items : []).map((item, index) => {
    const pricing = item.pricing && typeof item.pricing === "object" ? item.pricing : {};
    const directTotal = firstFiniteNumber(pricing.total_price, item.total_price, item.subtotal, item.sub_total);
    if (directTotal !== null) return directTotal;
    return lines[index].price * lines[index].qty;
  });
  const payloadTotal = firstFiniteNumber(
    payment.order_total,
    payment.sub_total,
    payment.total,
    order.total,
    order.totalPrice,
    order.total_price
  );
  const linesTotal = lineTotals.reduce((sum, value) => sum + value, 0);
  const total = payloadTotal > 0 ? payloadTotal : linesTotal;

  return {
    id: `glovo-${externalId}`,
    externalOrderId: externalId,
    source: "glovo",
    customerName: "Ordine Glovo",
    serviceType: "delivery",
    status: order.state || order.status || "new",
    total: Number(total.toFixed(2)),
    currency: order.currency || payment.currency || "EUR",
    channel: "Glovo",
    collectionCode: order.shortCode || order.orderCode || order.order_code || externalId,
    pickupTime: order.transport?.pickupTime || order.pickupAt || order.deliverAt || order.promised_for || null,
    notes: order.comment || order.customerNote || "",
    items: lines,
    selectedCourse: 1,
    activeCourse: 1,
    kitchenClosed: false,
    receivedAt: new Date().toISOString(),
    glovoPayload: order
  };
}

module.exports = { normalizeGlovoOrder };
