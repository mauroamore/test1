const { createCanvas, GlobalFonts } = require("@napi-rs/canvas");

const MONO_FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
try {
  GlobalFonts.registerFromPath(MONO_FONT, "ReceiptMono");
} catch (_) {
  // The desktop fallback keeps local preview and development working.
}

const WIDTH_58 = 384;
const WIDTH_80 = 512;
const MARGIN = 24;
const LINE = 34;

function graphicFontScale(fontSize) {
  return ({ 5: [2, 1], 6: [1, 2], 2: [2, 2], 3: [3, 3], 4: [4, 4] })[Number(fontSize)] || [1, 1];
}

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
    const left = Math.max(0, Math.floor((width - text.length) / 2));
    return " ".repeat(left) + text;
  };
  const amount = value => euro(value).padStart(width);
  const itemRow = (left, right) => {
    const value = String(left || "");
    const price = String(right || "");
    const maxLeft = Math.max(1, width - price.length - 1);
    return value.slice(0, maxLeft).padEnd(maxLeft) + " " + price;
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

function buildGraphicPreconto(order, settings = {}) {
  const width = Number(settings.width) === 80 ? WIDTH_80 : WIDTH_58;
  const font = width === WIDTH_58 ? 20 : 22;
  const items = Array.isArray(order.items) ? order.items : [];
  const covers = Number(order.covers || 0);
  const coverPrice = Number(settings.coverCharge || 0);
  const rows = items.length + (covers ? 1 : 0) + 10;
  const canvas = createCanvas(width, MARGIN * 2 + rows * LINE);
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, width, canvas.height);
  ctx.fillStyle = "#000";
  ctx.font = `bold ${font}px ReceiptMono`;
  ctx.textBaseline = "top";
  let y = MARGIN;
  const sep = () => { ctx.fillRect(MARGIN, y + 12, width - MARGIN * 2, 2); y += LINE; };
  const centered = text => {
    ctx.textAlign = "center";
    let value = String(text);
    while (ctx.measureText(value).width > width - MARGIN * 2 && value.length > 4) value = `${value.slice(0, -4)}...`;
    ctx.fillText(value, width / 2, y); y += LINE;
  };
  const row = (left, right, bold = false) => {
    ctx.font = `${bold ? "bold " : ""}${font}px ReceiptMono`;
    const rightText = String(right || "");
    const maxLeft = Math.max(40, width - MARGIN * 2 - ctx.measureText(rightText).width - 12);
    let leftText = String(left || "");
    while (ctx.measureText(leftText).width > maxLeft && leftText.length > 4) leftText = `${leftText.slice(0, -4)}...`;
    ctx.textAlign = "left"; ctx.fillText(leftText, MARGIN, y);
    if (rightText) { ctx.textAlign = "right"; ctx.fillText(rightText, width - MARGIN, y); }
    y += LINE;
  };
  centered("Thai Princess");
  centered("PRECONTO NON FISCALE");
  row(order.tableName || order.table || `Tavolo ${order.id || ""}`, "");
  sep();
  if (covers) row(`${covers} x Coperto`, euro(covers * coverPrice));
  for (const item of items) {
    const qty = Number(item.qty || item.quantity || 0);
    const price = qty * (Number(item.price || item.unit_price || 0) + Number(item.extraTotal || 0));
    row(`${qty} x ${String(item.name || item.product_name || "Articolo")}`, euro(price));
  }
  sep();
  const original = items.reduce((sum, item) => sum + Number(item.qty || item.quantity || 0) * (Number(item.price || item.unit_price || 0) + Number(item.extraTotal || 0)), covers * coverPrice);
  const discount = Math.max(0, Number(order.discount || 0));
  row("Totale", euro(original));
  if (discount > 0) {
    row("Sconto", `-${euro(discount)}`);
    row("Nuovo Totale", euro(Math.max(0, original - discount)), true);
  }
  sep();
  centered("Documento non fiscale");
  centered("Il presente preconto");
  centered("non ha valore fiscale");
  return canvas;
}

async function printGraphicPreconto(order, printer, settings = {}) {
  const canvas = buildGraphicPreconto(order, settings);
  return printGraphicCanvas(canvas, printer);
}

function buildGraphicOrder(order, printerSettings = {}) {
  const width = Number(printerSettings.width) === 80 ? WIDTH_80 : WIDTH_58;
  const [scaleX, scaleY] = graphicFontScale(printerSettings.fontSize);
  const logicalWidth = width / scaleX;
  const margin = 20;
  const font = 19;
  const lineHeight = 25;
  const rows = [];
  const textContext = createCanvas(1, 1).getContext("2d");
  const addText = (text, size = font, bold = false, kind = "text") => {
    textContext.font = `${bold ? "bold " : ""}${size}px ReceiptMono`;
    const maxWidth = logicalWidth - margin * 2;
    const words = String(text || "").split(/\s+/).filter(Boolean);
    let current = "";
    const wrapped = [];
    for (const word of words) {
      const candidate = current ? `${current} ${word}` : word;
      if (current && textContext.measureText(candidate).width > maxWidth) {
        wrapped.push(current);
        current = word;
      } else {
        current = candidate;
      }
    }
    if (current) wrapped.push(current);
    (wrapped.length ? wrapped : [""]).forEach(value => rows.push({ text: value, size, bold, kind }));
  };
  const addRule = () => rows.push({ kind: "rule" });

  addText("Thai Princess", font, true, "center");
  addText("ORDINE", font + 1, true, "center");
  if (order.source) {
    addText(`TakeAway - ${order.customerName || order.name || order.id || "Ordine"}`, font, true);
    addText(order.pickupTime || "Subito", font - 1, false);
  } else {
    addText(order.tableName || order.table || `Tavolo ${order.id || ""}`, font, true);
  }
  addRule();

  let previousSequence = null;
  for (const item of Array.isArray(order.items) ? order.items : []) {
    if (item.usesTurns) {
      const sequence = Math.max(0, Number(item.course) || 0);
      if (sequence !== previousSequence) {
        addText(`Sequenza ${sequence}`, font, true, "sequence");
        previousSequence = sequence;
      }
    } else {
      previousSequence = null;
    }
    addText(`${Number(item.qty || 0)} x ${item.name || "Articolo"}`, font, true, "item");
    if (item.lineNote) addText(item.lineNote, font - 2, false, "note");
    if (item.variations) addText(item.variations, Math.max(12, font - 4), false, "variation");
  }

  const physicalHeight = Math.ceil((margin + rows.reduce((total, row) => total + (row.kind === "rule" ? 14 : lineHeight), 0) + margin) * scaleY);
  const canvas = createCanvas(width, physicalHeight);
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, width, physicalHeight);
  ctx.save();
  ctx.scale(scaleX, scaleY);
  ctx.fillStyle = "#000";
  ctx.textBaseline = "top";
  let y = margin;
  for (const row of rows) {
    if (row.kind === "rule") {
      ctx.fillRect(margin, y + 7, logicalWidth - margin * 2, 2);
      y += 14;
      continue;
    }
    ctx.font = `${row.bold ? "bold " : ""}${row.size}px ReceiptMono`;
    ctx.textAlign = row.kind === "center" ? "center" : "left";
    ctx.fillText(row.text, row.kind === "center" ? logicalWidth / 2 : margin, y);
    y += lineHeight;
  }
  ctx.restore();
  return canvas;
}

async function printGraphicOrder(order, printer) {
  return printGraphicCanvas(buildGraphicOrder(order, printer), printer);
}

async function printGraphicCanvas(canvas, printer) {
  const png = canvas.toBuffer("image/png");
  const { Image, Printer } = await import("@node-escpos/core");
  const { default: Network } = await import("@node-escpos/network-adapter");
  const device = new Network(printer.host, Number(printer.port || 9100));
  await new Promise((resolve, reject) => device.open(error => error ? reject(error) : resolve()));
  const image = await Image.load(png, "image/png");
  // Decode directly from the canvas. The generic PNG decoder used by
  // escpos can lose antialiased glyphs and leave only solid separator rows.
  const pixels = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
  const black = (x, y) => {
    const offset = (y * canvas.width + x) * 4;
    return 255 - ((pixels[offset] + pixels[offset + 1] + pixels[offset + 2]) / 3) > 96;
  };
  const bytesPerRow = Math.ceil(canvas.width / 8);
  const rasterData = Buffer.alloc(bytesPerRow * canvas.height);
  for (let y = 0; y < canvas.height; y++) {
    for (let x = 0; x < canvas.width; x++) {
      if (black(x, y)) rasterData[y * bytesPerRow + Math.floor(x / 8)] |= 128 >> (x % 8);
    }
  }
  image.toRaster = () => ({ data: rasterData, width: bytesPerRow, height: canvas.height });
  const output = new Printer(device, {});
  await output.raster(image).feed(3).cut().close();
  return { pngBase64: png.toString("base64"), width: canvas.width, height: canvas.height };
}

module.exports = { buildGraphicOrder, buildGraphicPreconto, buildPcPosPrecontoLines, printGraphicOrder, printGraphicPreconto };
