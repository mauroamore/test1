function euro(value) {
  return `${Number(value || 0).toFixed(2).replace(".", ",")} EUR`;
}

function buildPcPosPrecontoLines(order, settings = {}) {
  const width = 40;
  const items = Array.isArray(order.items) ? order.items : [];
  const covers = Number(order.covers || 0);
  const coverPrice = Number(settings.coverCharge || 0);
  const discount = Math.max(0, Number(order.discount || 0));
  const rows = [];
  const center = value => {
    const text = String(value || "").slice(0, width);
    return " ".repeat(Math.max(0, Math.floor((width - text.length) / 2))) + text;
  };
  const itemRow = (left, right) => {
    const price = String(right || "");
    const maxLeft = Math.max(1, width - price.length - 1);
    return String(left || "").slice(0, maxLeft).padEnd(maxLeft) + " " + price;
  };
  rows.push(center("Thai Princess"), center("PRECONTO NON FISCALE"));
  rows.push(`Tavolo ${order.tableName || order.table || order.id || ""}`.slice(0, width));
  rows.push("-".repeat(width));
  if (covers) rows.push(itemRow(`${covers} x Coperto`, euro(covers * coverPrice)));
  for (const item of items) {
    const qty = Number(item.qty || item.quantity || 0);
    const price = qty * (Number(item.price || item.unit_price || 0) + Number(item.extraTotal || 0));
    rows.push(itemRow(`${qty} x ${item.name || item.product_name || "Articolo"}`, euro(price)));
  }
  const original = items.reduce((sum, item) => sum + Number(item.qty || item.quantity || 0) * (Number(item.price || item.unit_price || 0) + Number(item.extraTotal || 0)), covers * coverPrice);
  rows.push("-".repeat(width), itemRow("Totale", euro(original)));
  if (discount > 0) {
    rows.push(itemRow("Sconto", `-${euro(discount)}`));
    rows.push(itemRow("Nuovo Totale", euro(Math.max(0, original - discount))));
  }
  rows.push("-".repeat(width), center("Documento non fiscale"), center("Il presente preconto"), center("non ha valore fiscale"));
  return rows;
}

module.exports = { buildPcPosPrecontoLines };
