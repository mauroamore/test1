const { createCanvas } = require("@napi-rs/canvas");

const WIDTH_58 = 384;
const MARGIN = 24;
const LINE = 34;

function euro(value) {
  return `${Number(value || 0).toFixed(2).replace(".", ",")} EUR`;
}

function buildGraphicPreconto(order, settings = {}) {
  const width = Number(settings.width) === 80 ? 576 : WIDTH_58;
  const font = width === WIDTH_58 ? 25 : 27;
  const items = Array.isArray(order.items) ? order.items : [];
  const covers = Number(order.covers || 0);
  const coverPrice = Number(settings.coverCharge || 0);
  const rows = items.length + (covers ? 1 : 0) + 10;
  const canvas = createCanvas(width, MARGIN * 2 + rows * LINE);
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, width, canvas.height);
  ctx.fillStyle = "#000";
  ctx.font = `bold ${font}px Courier New`;
  ctx.textBaseline = "top";
  let y = MARGIN;
  const sep = () => { ctx.fillRect(MARGIN, y + 12, width - MARGIN * 2, 2); y += LINE; };
  const centered = text => { ctx.textAlign = "center"; ctx.fillText(text, width / 2, y); y += LINE; };
  const row = (left, right, bold = false) => {
    ctx.font = `${bold ? "bold " : ""}${font}px Courier New`;
    ctx.textAlign = "left"; ctx.fillText(String(left), MARGIN, y);
    ctx.textAlign = "right"; ctx.fillText(String(right), width - MARGIN, y); y += LINE;
  };
  centered("Thai Princess");
  centered("PRECONTO NON FISCALE");
  row(order.tableName || order.table || `Tavolo ${order.id || ""}`, "");
  sep();
  if (covers) row(`${covers} x Coperto`, euro(covers * coverPrice));
  for (const item of items) {
    const qty = Number(item.qty || item.quantity || 0);
    const price = qty * (Number(item.price || item.unit_price || 0) + Number(item.extraTotal || 0));
    row(`${qty} x ${String(item.name || item.product_name || "Articolo").slice(0, 24)}`, euro(price));
  }
  sep();
  const original = items.reduce((sum, item) => sum + Number(item.qty || item.quantity || 0) * (Number(item.price || item.unit_price || 0) + Number(item.extraTotal || 0)), covers * coverPrice);
  const discount = Math.max(0, Number(order.discount || 0));
  row("Totale originale", euro(original));
  if (discount > 0) row("Sconto", `-${euro(discount)}`);
  row("TOTALE", euro(Math.max(0, original - discount)), true);
  sep();
  centered("Documento non fiscale");
  centered("Il presente preconto non ha valore fiscale");
  return canvas;
}

async function printGraphicPreconto(order, printer, settings = {}) {
  const canvas = buildGraphicPreconto(order, settings);
  const png = canvas.toBuffer("image/png");
  const { Image, Printer } = await import("@node-escpos/core");
  const { default: Network } = await import("@node-escpos/network-adapter");
  const device = new Network(printer.host, Number(printer.port || 9100));
  await new Promise((resolve, reject) => device.open(error => error ? reject(error) : resolve()));
  const image = await Image.load(png, "image/png");
  const output = new Printer(device, {});
  await output.raster(image).feed(3).cut().close();
  return { pngBase64: png.toString("base64"), width: canvas.width, height: canvas.height };
}

module.exports = { buildGraphicPreconto, printGraphicPreconto };
