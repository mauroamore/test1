const http = require("http");
const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");
const { normalizeHubRiseOrder, applyHubRiseStatusUpdate, migrateStateToHubRiseShape } = require("./src/external-order-normalization");
const epsonFiscal = require("./EpsonFiscalClient.js");
let printGraphicPreconto;

function loadLocalEnv(filePath) {
  if (!fs.existsSync(filePath)) return;
  for (const rawLine of fs.readFileSync(filePath, "utf8").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator <= 0) continue;
    const name = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (process.env[name] === undefined) process.env[name] = value;
  }
}

loadLocalEnv(path.join(__dirname, ".env"));

const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || undefined; // undefined = tutte le interfacce (serve ai palmari in LAN)
const ROOT = __dirname;
const APP_VERSION = (() => {
  try {
    return childProcess.execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: ROOT, encoding: "utf8" }).trim();
  } catch (error) {
    return process.env.APP_VERSION || "local";
  }
})();
const REMOTE_BASE_URL = (process.env.REMOTE_BASE_URL || "https://servizi.thaiprincess.it").replace(/\/$/, "");
const STATE_FILE = path.join(ROOT, "ristorante-state.json");
const MENU_CACHE_FILE = path.join(ROOT, "menu-cache.json");
const CONFIG_FILE = path.join(ROOT, "restaurant-config.json");
const PRINT_LOG = path.join(ROOT, "print-simulation.log");
const DELIVEROO_WEBHOOK_LOG = path.join(ROOT, "deliveroo-webhook.log");
const HUBRISE_FEED_LOG = path.join(ROOT, "hubrise-feed.log");
const HUBRISE_FEED_URL = process.env.HUBRISE_FEED_URL || `${REMOTE_BASE_URL}/HubRiseOrdersFeed.ashx`;
const HUBRISE_FEED_KEY = process.env.HUBRISE_FEED_KEY || "";
const HUBRISE_POLL_INTERVAL_MS = Number(process.env.HUBRISE_POLL_INTERVAL_MS || 20000);
// Keep this aligned with the published Sigonella admin dashboard.
const SIGONELLA_ORDERS_URL = process.env.SIGONELLA_ORDERS_URL || `${REMOTE_BASE_URL}/StandardOrderService.asmx/GetOrders`;
const SIGONELLA_ORDERS_INTERVAL_MS = Number(process.env.SIGONELLA_ORDERS_INTERVAL_MS || 10000);
const SIGONELLA_ORDERS_LOG = path.join(ROOT, "sigonella-orders.log");
const SIGONELLA_MENU_URL = process.env.SIGONELLA_MENU_URL || `${REMOTE_BASE_URL}/StandardOrderService.asmx/GetMenu`;
const SIGONELLA_UPDATE_ORDER_URL = process.env.SIGONELLA_UPDATE_ORDER_URL || `${REMOTE_BASE_URL}/StandardOrderService.asmx/UpdateConfirmedOrder`;
const POS_SERVICE_URL = process.env.POS_SERVICE_URL || `${REMOTE_BASE_URL}/StandardOrderService.asmx`;
const POS_API_KEY = process.env.POS_API_KEY || "";
const HUBRISE_STATUS_URL = process.env.HUBRISE_STATUS_URL || `${REMOTE_BASE_URL}/HubRiseOrderStatus.ashx`;
const HUBRISE_STATUS_KEY = process.env.HUBRISE_STATUS_KEY || "";

function appendLog(file, line) {
  try { fs.appendFileSync(file, line); } catch (error) {
    console.warn(`Impossibile scrivere il log ${file}: ${error.code || error.message}`);
  }
}
const RESTAURANT_SYNC_LOG = path.join(ROOT, "restaurant-sync.log");
const RESTAURANT_SYNC_URL = process.env.RESTAURANT_SYNC_URL || `${REMOTE_BASE_URL}/RestaurantSync.ashx`;
const RESTAURANT_SYNC_KEY = process.env.RESTAURANT_SYNC_KEY || "";
const RESTAURANT_SYNC_INTERVAL_MS = Number(process.env.RESTAURANT_SYNC_INTERVAL_MS || 5000);
const REALTIME_URL = (process.env.REALTIME_URL || "https://vorrei-realtime.onrender.com").replace(/\/$/, "");
const REALTIME_KEY = process.env.REALTIME_KEY || RESTAURANT_SYNC_KEY;
const UPDATE_KEY = process.env.UPDATE_KEY || "";
const SERVICE_NAME = process.env.SERVICE_NAME || "gestione-comande.service";
const RESERVATIONS_REMOTE_URL = process.env.RESERVATIONS_REMOTE_URL || `${REMOTE_BASE_URL}/ReservationsNew.html`;
const clients = new Set();
const tableLocks = new Map();
let updateInProgress = false;
let fiscalReceiptInProgress = false;
const TABLE_LOCK_TTL_MS = 15000;
function readJsonFile(filePath, fallback = null) {
  try {
    return fs.existsSync(filePath) ? JSON.parse(fs.readFileSync(filePath, "utf8")) : fallback;
  } catch (error) {
    console.warn(`Impossibile leggere ${filePath}: ${error.message}`);
    return fallback;
  }
}

function stateForStorage(state) {
  if (!state) return state;
  const snapshot = { ...state };
  delete snapshot.menu;
  delete snapshot.room;
  delete snapshot.settings;
  if (Array.isArray(snapshot.tables)) {
    snapshot.tables = snapshot.tables.map(table => {
      const runtimeTable = { ...table };
      delete runtimeTable.x;
      delete runtimeTable.y;
      return runtimeTable;
    });
  }
  return snapshot;
}

function configForStorage(state) {
  return {
    room: state.room || {},
    settings: state.settings || {},
    tableLayout: Array.isArray(state.tables)
      ? state.tables.map(table => ({ id: table.id, x: table.x, y: table.y }))
      : []
  };
}

function persistStateFiles() {
  if (!sharedState) return;
  if (sharedState.menu) fs.writeFileSync(MENU_CACHE_FILE, JSON.stringify(sharedState.menu, null, 2));
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(configForStorage(sharedState), null, 2));
  fs.writeFileSync(STATE_FILE, JSON.stringify(stateForStorage(sharedState), null, 2));
}

const persistedState = readJsonFile(STATE_FILE);
const persistedMenu = readJsonFile(MENU_CACHE_FILE);
const persistedConfig = readJsonFile(CONFIG_FILE);
let sharedState = persistedState ? migrateStateToHubRiseShape(persistedState) : null;
if (sharedState && persistedConfig) {
  sharedState.room = persistedConfig.room || sharedState.room;
  sharedState.settings = persistedConfig.settings || sharedState.settings;
  const layouts = new Map((persistedConfig.tableLayout || []).map(table => [String(table.id), table]));
  if (Array.isArray(sharedState.tables)) {
    sharedState.tables.forEach(table => {
      const layout = layouts.get(String(table.id));
      if (layout) {
        table.x = layout.x;
        table.y = layout.y;
      }
    });
  }
}
if (sharedState && (!Array.isArray(sharedState.menu) || sharedState.menu.length === 0) && Array.isArray(persistedMenu) && persistedMenu.length > 0) {
  sharedState.menu = persistedMenu;
}
// Backward compatibility: migrate an old combined snapshot on first startup.
if (sharedState && (sharedState.menu || !persistedConfig)) persistStateFiles();
let sigonellaMenuCatalog = new Map();
let sharedMenuPayload = null;

async function loadSharedMenuCatalog() {
  if (sigonellaMenuCatalog.size) return sigonellaMenuCatalog;
  const response = await fetch(SIGONELLA_MENU_URL, { method: "POST", headers: { "Content-Type": "application/json; charset=utf-8", Accept: "application/json" }, body: "{}" });
  if (!response.ok) throw new Error("Menu HTTP " + response.status);
  const xml = await response.text();
  const match = xml.match(/<string[^>]*>([\s\S]*?)<\/string>/i);
  if (!match) throw new Error("Risposta menu non valida");
  const categories = JSON.parse(match[1]
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&"));
  const catalog = new Map();
  for (const category of Array.isArray(categories) ? categories : []) {
    for (const item of Array.isArray(category.items) ? category.items : []) {
      catalog.set(String(item.id), {
        id: item.id,
        name: item.name || item.eng || String(item.id),
        price: Number(item.price || 0),
        category: category.name || ""
      });
    }
  }
  sigonellaMenuCatalog = catalog;
  sharedMenuPayload = categories;
  if (sharedState && (!Array.isArray(sharedState.menu) || sharedState.menu.length === 0) && categories.length > 0) {
    sharedState.menu = categories;
    persistStateFiles();
  }
  return catalog;
}
if (sharedState && !Number.isFinite(Number(sharedState.stateRevision))) sharedState.stateRevision = 1;

function sendJson(response, status, body) {
  response.writeHead(status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
  response.end(JSON.stringify(body));
}

function updateAuthorized(request) {
  if (!UPDATE_KEY) return false;
  const headerKey = request.headers["x-update-key"] || "";
  return headerKey === UPDATE_KEY;
}

function runUpdateScript() {
  return new Promise((resolve, reject) => {
    const script = path.join(ROOT, "scripts", "update-app.sh");
    childProcess.execFile("bash", [script], { cwd: ROOT, timeout: 180000, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) return reject(new Error((stderr || stdout || error.message).trim()));
      resolve((stdout || "Aggiornamento completato").trim());
    });
  });
}

function scheduleServiceRestart() {
  setTimeout(() => {
    childProcess.execFile("sudo", ["-n", "systemctl", "restart", SERVICE_NAME], { cwd: ROOT, timeout: 30000 }, error => {
      if (error) appendLog(path.join(ROOT, "update.log"), `${new Date().toISOString()} riavvio fallito: ${error.message}\n`);
    });
  }, 1500).unref();
}

function publishRealtimeEvent(event, data = {}) {
  if (!REALTIME_KEY) return;
  fetch(`${REALTIME_URL}/publish`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${REALTIME_KEY}` },
    body: JSON.stringify({ channel: "restaurant", event, data })
  }).catch(error => appendLog(RESTAURANT_SYNC_LOG, `${new Date().toISOString()} realtime ${error.message}\n`));
}

function broadcast(event = "state.updated", data = {}) {
  broadcastLocal(event, data);
  publishRealtimeEvent(event, data);
}

function broadcastLocal(event = "state.updated", data = {}) {
  const message = { type: "state-updated", event, data };
  for (const response of clients) response.write(`data: ${JSON.stringify(message)}\n\n`);
}

// The local browser clients listen to Node's SSE stream. Keep Node subscribed
// to the shared Render channel so events produced by ReservationsNew reach the
// LAN immediately instead of waiting for the reservation polling interval.
function connectRealtimeBridge() {
  if (!REALTIME_KEY || typeof WebSocket === "undefined") return;
  const realtimeSocketUrl = `${REALTIME_URL.replace(/^http/, "ws")}/realtime?channel=restaurant&key=${encodeURIComponent(REALTIME_KEY)}`;
  const connect = () => {
    const socket = new WebSocket(realtimeSocketUrl);
    socket.addEventListener("message", message => {
      try {
        const event = JSON.parse(message.data);
        if (event.event && event.event !== "connected") {
          const data = event.payload || event.data || {};
          if (event.event === "pos.payment") processPosPaymentEvent(data).catch(error => appendLog(RESTAURANT_SYNC_LOG, `${new Date().toISOString()} pos.payment ${error.message}\n`));
          else broadcastLocal(event.event, data);
        }
      } catch (error) {
        appendLog(RESTAURANT_SYNC_LOG, `${new Date().toISOString()} realtime bridge parse ${error.message}\n`);
      }
    });
    socket.addEventListener("close", () => setTimeout(connect, 3000));
    socket.addEventListener("error", () => {});
  };
  connect();
}

const posTransactionsInProgress = new Set();

// Stampa raw ESC/POS per stampanti termiche Epson (TCP/9100).
function printEscPosRaw(host, port, text, { timeoutMs = 7000, cut = true } = {}) {
  return new Promise((resolve, reject) => {
    const net = require("net");
    const socket = net.createConnection({ host, port }, () => {
      const body = Buffer.isBuffer(text) ? text : Buffer.from(String(text || ""), "utf8");
      // Lascia spazio sufficiente prima del taglio: alcune Epson tagliano il
      // rotolo mentre l'ultima riga è ancora troppo vicina alla lama.
      const chunks = [Buffer.from([0x1b, 0x40]), body, Buffer.from("\n\n\n\n\n\n\n\n", "ascii")];
      if (cut) chunks.push(Buffer.from([0x1d, 0x56, 0x00]));
      socket.end(Buffer.concat(chunks));
    });
    const timer = setTimeout(() => socket.destroy(new Error("Timeout connessione stampante")), timeoutMs);
    socket.on("error", error => { clearTimeout(timer); reject(error); });
    socket.on("close", hadError => { clearTimeout(timer); if (!hadError) resolve({ ok: true, host, port }); });
  });
}

async function callPosService(method, body) {
  const response = await fetch(`${POS_SERVICE_URL}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Accept: "application/json", "X-Api-Key": POS_API_KEY },
    body: JSON.stringify(body || {})
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} HTTP ${response.status}: ${text.slice(0, 500)}`);
  let value = JSON.parse(text);
  if (value && typeof value.d === "string") value = JSON.parse(value.d);
  else if (value && value.d !== undefined) value = value.d;
  return value;
}

async function processPosPaymentEvent(eventData) {
  const transactionId = String(eventData.transactionId || "");
  if (!transactionId || posTransactionsInProgress.has(transactionId)) return;
  posTransactionsInProgress.add(transactionId);
  try {
    const pending = await callPosService("WaitPosPayment", { deviceId: eventData.deviceId, timeoutSeconds: 5 });
    if (!pending || !pending.available) return;
    let payment = pending.payment;
    if (typeof payment === "string") payment = JSON.parse(payment);
    const orderResponse = await callPosService("GetOrder", { id: eventData.orderId });
    let order = orderResponse && orderResponse.order ? orderResponse.order : orderResponse;
    const rawItems = Array.isArray(order && order.items) ? order.items : Array.isArray(order && order.lines) ? order.lines : [];
    const items = rawItems.map(item => ({
      description: String(item.product_name || item.name || `Articolo ${item.id || ""}`),
      quantity: Number(item.quantity || item.count || 1),
      unitPrice: Number(item.unit_price ?? item.price ?? 0),
      department: "2",
      justification: "1"
    }));
    const printer = sharedState && sharedState.settings && sharedState.settings.fiscalPrinter;
    if (!printer || printer.enabled !== true || !printer.host) throw new Error("Stampante fiscale non configurata");
    const paymentType = String(payment.paymentStatus || "").toUpperCase() === "CASH" ? "0" : "2";
    const receiptInput = epsonFiscal.applyOneCentTestMode({
      operator: String(printer.operator || "1"),
      items,
      payment: { description: paymentType === "0" ? "Contanti" : "Carta", amount: Number(payment.paidAmount || payment.amount || 0), paymentType }
    }, { enabled: printer.testModeOneCent === true, department: printer.defaultDepartment || "2" });
    const result = await epsonFiscal.printFiscalReceipt(printer.host, receiptInput, { port: Number(printer.port || 80), devid: printer.devid || "local_printer" });
    const status = result.success ? "issued" : "failed";
    await callPosService("CompletePosReceipt", {
      transactionId,
      status,
      receiptJson: JSON.stringify({ transactionId, result, orderId: eventData.orderId }),
      errorCode: result.success ? "" : String(result.code || "FISCAL_PRINT_FAILED"),
      errorMessage: result.success ? "" : String(result.status || "Fiscal printer error")
    });
  } finally {
    posTransactionsInProgress.delete(transactionId);
  }
}

function handleDeliverooWebhook(request, response) {
  let body = "";
  request.on("data", chunk => {
    body += chunk;
    if (body.length > 2 * 1024 * 1024) request.destroy();
  });
  request.on("end", () => {
    const entry = {
      receivedAt: new Date().toISOString(),
      path: request.url,
      headers: request.headers,
      body: (() => {
        try { return JSON.parse(body || "{}"); } catch { return body; }
      })()
    };
    fs.appendFileSync(DELIVEROO_WEBHOOK_LOG, `${JSON.stringify(entry)}\n`);
    sendJson(response, 200, { ok: true, received: true });
  });
}

function handleReservationsProxy(request, response) {
  const method = new URL(request.url, "http://localhost").searchParams.get("method");
  const allowed = new Set(["GetReservations", "UpdateReservation", "InsertWalkin"]);
  if (!allowed.has(method)) return sendJson(response, 400, { error: "Metodo prenotazioni non valido" });
  let body = "";
  request.on("data", chunk => body += chunk);
  request.on("end", async () => {
    try {
      const upstream = await fetch(`${REMOTE_BASE_URL}/Sigonella.aspx/${method}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=utf-8", Accept: "application/json" },
        body: body || "{}"
      });
      const text = await upstream.text();
      if (upstream.ok && method !== "GetReservations") {
        broadcast("reservation.updated", { method });
      }
      response.writeHead(upstream.status, { "Content-Type": "application/json; charset=utf-8" });
      response.end(text);
    } catch (error) {
      sendJson(response, 502, { error: "Servizio prenotazioni non disponibile", detail: error.message });
    }
  });
}

function mergeDeliveryOrders(newOrders) {
  if (!sharedState) return;
  if (!Array.isArray(sharedState.deliveryOrders)) sharedState.deliveryOrders = [];
  for (const order of newOrders) {
    const index = sharedState.deliveryOrders.findIndex(existing => existing.id === order.id);
    if (index >= 0) {
      const existing = sharedState.deliveryOrders[index];
      sharedState.deliveryOrders[index] = existing.source === "hubrise"
        ? applyHubRiseStatusUpdate(existing, order)
        : order;
    }
    else sharedState.deliveryOrders.push(order);
  }
}

function setHubRiseFeedStatus(ok, error) {
  if (!sharedState) return;
  sharedState.hubriseFeedStatus = { ok, error: error || null, checkedAt: new Date().toISOString() };
}

function unwrapAspNetJson(payload) {
  if (!payload) return null;
  if (typeof payload.d === "string") {
    try { return JSON.parse(payload.d); } catch { return payload.d; }
  }
  return payload.d || payload;
}

function extractSigonellaOrders(payload) {
  let value = unwrapAspNetJson(payload);
  for (let depth = 0; depth < 3; depth += 1) {
    if (typeof value === "string") {
      try { value = JSON.parse(value); } catch { break; }
    }
    if (Array.isArray(value)) return value;
    if (value && Array.isArray(value.orders)) return value.orders;
    if (value && value.data) { value = value.data; continue; }
    if (value && value.result) { value = value.result; continue; }
    break;
  }
  return [];
}

function isConfirmedSigonellaOrder(order) {
  const status = String(order.status || order.state || order.orderStatus || "").toLowerCase();
  const numericStatus = Number(order.stato);
  const notDeleted = order.deleted !== true && order.Eliminato !== true && order.Eliminato !== 1 && String(order.Eliminato).toLowerCase() !== "true";
  return notDeleted && (
    Boolean(order.external_order_id) ||
    order.confirmed === true ||
    (!Number.isNaN(numericStatus) && numericStatus >= 2) ||
    ["submitted", "confirmed", "confermato", "accepted", "approved", "ready_for_pickup", "in_transit", "ready_for_collection"].includes(status)
  );
}

function currentRomeDateKey() {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Rome",
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.filter(part => part.type !== "literal").map(part => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

async function refreshSigonellaMenuCatalog() {
  const catalog = await loadSharedMenuCatalog();
  return catalog.size;
}

function normalizeSigonellaOrder(order) {
  const customer = order.customer && typeof order.customer === "object" ? order.customer : {};
  const externalId = String(order.external_order_id || order.id || order.uuid || order.orderId || order.ID || "");
  const items = Array.isArray(order.items) ? order.items : [];
  const normalizedItems = items.map(item => {
    const catalogItem = sigonellaMenuCatalog.get(String(item.id || item.product_id || item.productId || item.articleId || ""));
    const quantity = Number(item.quantity || item.qty || item.count || 1);
    const name = item.product_name || item.sku_name || item.name || item.description || (catalogItem && catalogItem.name) || item.id || "Articolo delivery";
    const unitPrice = Number(item.price || item.unit_price || item.unitPrice || item.prezzo || (catalogItem && catalogItem.price) || 0);
    const note = item.customer_notes || item.modifications || item.note || item.notes || "";
    return {
      id: item.id || item.product_id || item.productId || item.articleId,
      name,
      category: item.category || (catalogItem && catalogItem.category) || "",
      quantity,
      unit_price: unitPrice,
      options: note ? [{ name: note }] : []
    };
  });
  return {
    id: `sigonella-${externalId}`,
    externalOrderId: externalId,
    source: "sigonella",
    orderDate: String(order.date || order.created_at || "").slice(0, 10),
    customerName: [customer.first_name, customer.last_name].filter(Boolean).join(" ") || order.customerName || order.name || "Ordine Sigonella",
    customerEmail: customer.email || order.email || "",
    customerPhone: customer.phone || order.phone || "",
    serviceType: order.service_type || order.serviceType || order.type || "delivery",
    status: order.status || "submitted",
    total: Number(order.total || order.totalPrice || order.totale || 0),
    currency: order.currency || "EUR",
    channel: "Sigonella Delivery",
    collectionCode: order.order_number || order.orderNumber || order.number || externalId,
    pickupTime: order.time || order.deliveryTime || null,
    notes: order.customer_notes || order.notes || order.note || "",
    items: normalizedItems.map((item, index) => {
      return {
      key: `sigonella-${externalId}-${index}`,
      id: item.id || `sigonella-item-${index}`,
      name: item.name,
      category: item.category,
      price: item.unit_price,
      originalPrice: item.unit_price,
      qty: item.quantity,
      sentQty: 0,
      course: 1,
      noTurns: true,
      kitchenStatus: undefined,
      minusVariations: [],
      plusVariations: [],
      lineNote: (item.options || []).map(option => option.name).filter(Boolean).join(", ")
      };
    }),
    selectedCourse: 1,
    activeCourse: 1,
    kitchenClosed: false,
    sigonellaPayload: order,
    receivedAt: new Date().toISOString()
  };
}

function mergeSigonellaOrders(orders) {
  if (!sharedState) return false;
  if (!Array.isArray(sharedState.deliveryOrders)) sharedState.deliveryOrders = [];
  let changed = false;
  for (const incoming of orders) {
    const existing = sharedState.deliveryOrders.find(item => item.id === incoming.id);
    if (!existing) {
      sharedState.deliveryOrders.push(incoming);
    appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} merge NEW id=${incoming.id} lines=${incoming.items.length} names=${incoming.items.map(line => line.name).join(" | ")}\n`);
      changed = true;
      continue;
    }
    // I dati del portale possono aggiornare anagrafica e note, ma non devono
    // sovrascrivere prezzo, righe o stato cucina modificati dall'operatore.
    existing.customerName = incoming.customerName || existing.customerName;
    existing.collectionCode = incoming.collectionCode || existing.collectionCode;
    existing.pickupTime = incoming.pickupTime || existing.pickupTime;
    existing.notes = incoming.notes || existing.notes;
    existing.externalStatus = incoming.status;
    // Lo stato logistico deciso da Sigonella deve aggiornare la colonna
    // Delivery & Pick-up; non modifica gli stati interni delle singole righe cucina.
    if (incoming.status) existing.status = incoming.status;
    const hasUnresolvedLines = Array.isArray(existing.items) && existing.items.some(line => {
      const name = String(line.name || "");
      return !name || name === String(line.id) || Number(line.price || 0) === 0;
    });
    if ((!existing.items?.length || hasUnresolvedLines) && !existing.sentToKitchen) {
      existing.items = incoming.items;
      existing.total = incoming.total;
      appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} merge UPDATE id=${incoming.id} unresolved=${hasUnresolvedLines} lines=${incoming.items.length} names=${incoming.items.map(line => line.name).join(" | ")}\n`);
    }
    changed = true;
  }
  return changed;
}

async function pollSigonellaOrders() {
  try {
    appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} poll start ${SIGONELLA_ORDERS_URL}\n`);
    if (!sigonellaMenuCatalog.size) {
      try {
        const count = await refreshSigonellaMenuCatalog();
        appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} menu catalog=${count}\n`);
      } catch (menuError) {
        appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} menu ${menuError.message}\n`);
      }
    }
    const response = await fetch(SIGONELLA_ORDERS_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=utf-8", Accept: "application/json" },
      body: "{}"
    });
    if (!response.ok) throw new Error("HTTP " + response.status);
    const rawResponse = await response.text();
    let envelope;
    try { envelope = JSON.parse(rawResponse); } catch { throw new Error("Risposta non JSON: " + rawResponse.slice(0, 300)); }
    appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} raw ${rawResponse.slice(0, 4000)}\n`);
    const orders = extractSigonellaOrders(envelope);
    const today = currentRomeDateKey();
    if (sharedState && Array.isArray(sharedState.deliveryOrders)) {
      const before = sharedState.deliveryOrders.length;
      sharedState.deliveryOrders = sharedState.deliveryOrders.filter(order => {
        if (order.source !== "sigonella") return true;
        return String(order.orderDate || "") === today;
      });
      if (before !== sharedState.deliveryOrders.length) {
        persistAndBroadcast();
      appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} pruned stale orders=${before - sharedState.deliveryOrders.length} today=${today}\n`);
      }
    }
    const todayOrders = orders.filter(order => !order.date || String(order.date || "").slice(0, 10) === today);
    const confirmed = todayOrders.filter(isConfirmedSigonellaOrder).filter(order => order.external_order_id || order.id || order.uuid || order.orderId || order.ID);
    const newOrders = confirmed.map(normalizeSigonellaOrder);
    const statuses = orders.map(order => {
      const status = order.status || order.state || order.orderStatus || (order.confirmed ? "confirmed" : "unknown");
      return `${status}/stato=${order.stato ?? ""}/Eliminato=${order.Eliminato ?? ""}`;
    }).join(",");
    appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} response orders=${orders.length} today=${today} todayOrders=${todayOrders.length} confirmed=${confirmed.length} statuses=${statuses}\n`);
    appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} normalized=${newOrders.map(order => `${order.id}[${order.items.length}]`).join(",") || "none"} stateBefore=${Array.isArray(sharedState && sharedState.deliveryOrders) ? sharedState.deliveryOrders.length : "null"}\n`);
    if (newOrders.length && mergeSigonellaOrders(newOrders)) {
      persistAndBroadcast();
      appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} persisted deliveryOrders=${sharedState.deliveryOrders.length}\n`);
    }
  } catch (error) {
    appendLog(SIGONELLA_ORDERS_LOG, `${new Date().toISOString()} ${error.message}\n`);
  }
}

function persistAndBroadcast(event = "state.updated", data = {}) {
  if (!sharedState) return;
  persistStateFiles();
  broadcast(event, data);
}

// Non deve mai bloccare o interrompere il server locale: qualunque errore di rete
// viene solo loggato, il prossimo giro di polling riprova da solo.
async function pollHubRiseOrders() {
  if (!HUBRISE_FEED_KEY) return;
  try {
    const url = HUBRISE_FEED_URL + "?key=" + encodeURIComponent(HUBRISE_FEED_KEY);
    const response = await fetch(url, { method: "GET" });
    if (!response.ok) throw new Error("HTTP " + response.status);
    const data = await response.json();
    if (data && data.state) {
      sharedState = data.state;
      sharedState.stateRevision = Number(sharedState.stateRevision || 0) + 1;
    persistStateFiles();
      broadcast();
    }
    const orders = Array.isArray(data.orders) ? data.orders : [];
    if (orders.length) {
      mergeDeliveryOrders(orders.map(normalizeHubRiseOrder));
    }
    setHubRiseFeedStatus(true);
    persistAndBroadcast();
  } catch (error) {
    fs.appendFileSync(HUBRISE_FEED_LOG, `${new Date().toISOString()} ${error.message}\n`);
    setHubRiseFeedStatus(false, error.message);
    persistAndBroadcast();
  }
}

// Ora locale di questa macchina (quella del ristorante, gia' nel fuso corretto) mandata a
// RestaurantSync.ashx: e' lui che, guardando restaurant_turno_types, decide a quale turno
// appartiene e se serve aprire una nuova riga in restaurant_state_snapshot. Non ci si fida
// dell'orologio dell'hosting remoto (potrebbe essere su un altro fuso).
function localNowString() {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  const hours = String(now.getHours()).padStart(2, "0");
  const minutes = String(now.getMinutes()).padStart(2, "0");
  const seconds = String(now.getSeconds()).padStart(2, "0");
  return `${year}-${month}-${day}T${hours}:${minutes}:${seconds}`;
}

// Spinge l'istantanea completa (autorevole) verso il DB remoto, cosi' l'istanza esterna la puo'
// leggere. Fallisce in silenzio come il polling HubRise: non deve mai bloccare l'uso locale.
async function pushStateSnapshot() {
  if (!RESTAURANT_SYNC_KEY || !sharedState) return;
  try {
    const url = RESTAURANT_SYNC_URL + "?mode=push_state&key=" + encodeURIComponent(RESTAURANT_SYNC_KEY) +
      "&now=" + encodeURIComponent(localNowString());
    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(stateForStorage(sharedState))
    });
    if (!response.ok) throw new Error("HTTP " + response.status);
  } catch (error) {
    fs.appendFileSync(RESTAURANT_SYNC_LOG, `${new Date().toISOString()} push_state ${error.message}\n`);
  }
}

// Trova un ordine Pick-up manuale (mai un tavolo, mai un ordine HubRise: quelli restano di sola
// lettura da remoto) su cui applicare un comando arrivato dall'istanza esterna.
function findManualDeliveryOrder(orderId) {
  if (!sharedState || !Array.isArray(sharedState.deliveryOrders)) return null;
  const order = sharedState.deliveryOrders.find(item => item.id === orderId);
  return order && order.source === "manual" ? order : null;
}

// Applica un singolo comando remoto. Ogni caso replica in poche righe la stessa mutazione che
// il browser farebbe in locale sugli ordini Pick-up manuali (vedi gestione-comande-ristorante.html:
// addPickupOrderBtn/pickupConfirmBtn, sendDeliveryOrderToKitchen, il click sulle kitchen-line,
// servedBtn). Ritorna true se il comando e' stato applicato (o e' comunque da considerare
// "consumato", es. bersaglio non valido), false se va ritentato al giro successivo.
function applyExternalCommand(command) {
  switch (command.type) {
    case "createPickupOrderAndSend": {
      // Un Pick-up remoto resta solo un'anteprima locale finche' non viene mandato in cucina:
      // questo comando arriva una volta sola, con l'ordine gia' completo di piatti, e lo crea
      // e lo invia in cucina in un solo colpo (equivalente a addPickupOrder + N addOrderLine +
      // sendToKitchen, ma senza traffico durante la composizione).
      if (!Array.isArray(sharedState.deliveryOrders)) sharedState.deliveryOrders = [];
      let order = sharedState.deliveryOrders.find(item => item.id === command.orderId);
      if (!order) {
        order = {
          id: command.orderId,
          source: "manual",
          customerName: command.customerName || "Nuovo ritiro",
          serviceType: "pickup",
          status: "new",
          channel: "Pick-up",
          total: null,
          currency: null,
          collectionCode: null,
          pickupTime: command.pickupTime || "Subito",
          items: [],
          items: [],
          selectedCourse: 1,
          activeCourse: 1,
          kitchenClosed: false,
          receivedAt: new Date().toISOString()
        };
        sharedState.deliveryOrders.push(order);
      } else {
        order.customerName = command.customerName || order.customerName;
        order.pickupTime = command.pickupTime || order.pickupTime;
      }
      if (command.notes) order.notes = command.notes;
      const lines = Array.isArray(command.items) ? command.items : [];
      order.items = lines.map(item => {
        const name = String(item.itemName || "").trim();
        const price = Number(item.itemPrice || 0);
        const qty = Math.max(1, Number(item.qty || 1));
        const key = `${item.itemId}::name=${name.toLowerCase()}::price=${price.toFixed(2)}::course=1::minus=::plus=`;
        return {
          id: item.itemId,
          key,
          name,
          originalName: name,
          category: item.itemCategory || "",
          price,
          minusVariations: [],
          plusVariations: [],
          lineNote: "",
          course: 1,
          splitAccount: "",
          qty,
          sentQty: qty,
          noTurns: true
        };
      });
      order.occupied = true;
      order.kitchenClosed = false;
      order.status = "Preparazione";
      return true;
    }
    case "open_table": {
      const table = (sharedState.tables || []).find(item => Number(item.id) === Number(command.tableId));
      if (!table || table.occupied || (table.items || []).length) return true;
      table.occupied = true;
      table.covers = Math.max(0, Number(command.covers || 0));
      table.coversEnteredAt = new Date().toISOString();
      table.status = "Nuova";
      table.tho = { ...(table.tho || {}), table_id: Number(command.tableId), covers: table.covers };
      if (command.reservationDecision === "same" && command.reservationId) {
        const reservation = (sharedState.reservations || []).find(item => String(item.id || item.reservationId || "") === String(command.reservationId));
        if (reservation) {
          reservation.status = "seated";
          reservation.tableIds = [Number(command.tableId)];
          table.tho.reservation_id = String(command.reservationId);
          table.tho.seated_reservation_id = String(command.reservationId);
        }
      } else {
        table.tho.source = "walk_in";
        table.tho.seated_reservation_id = "walkin-" + Date.now();
      }
      return true;
    }
    case "adopt_walkin":
    case "move_reservation": {
      const table = (sharedState.tables || []).find(item => Number(item.id) === Number(command.tableId));
      const reservation = (sharedState.reservations || []).find(item => String(item.id || item.reservationId || "") === String(command.reservationId || ""));
      if (!table || !reservation || (table.items || []).length) return true;
      reservation.status = "seated";
      reservation.tableIds = [Number(command.tableId)];
      table.occupied = true;
      table.status = "Nuova";
      table.tho = { ...(table.tho || {}), table_id: Number(command.tableId), reservation_id: String(command.reservationId), seated_reservation_id: String(command.reservationId), source: "reservation", table_status: "seduto" };
      return true;
    }
    case "clear_reservation": {
      const reservationId = String(command.reservationId || command.reservation_id || "");
      const tableIds = Array.isArray(command.tableIds) ? command.tableIds.map(Number) : [];
      (sharedState.tables || []).forEach(table => {
        const tho = table.tho || {};
        const matchesReservation = String(tho.reservation_id || tho.seated_reservation_id || "") === reservationId;
        if (!matchesReservation && tableIds.indexOf(Number(table.id)) < 0) return;
        table.items = [];
        table.occupied = false;
        table.covers = 0;
        table.coversEnteredAt = null;
        table.status = "Libero";
        delete table.customer;
        table.tho = { ...tho };
        delete table.tho.reservation_id;
        delete table.tho.seated_reservation_id;
      });
      return true;
    }
    case "sendToKitchen": {
      const order = findManualDeliveryOrder(command.orderId);
      if (!order) return true;
      (order.items || []).forEach(line => { line.sentQty = Math.max(0, Number(line.qty || 0)); });
      order.status = "Preparazione";
      return true;
    }
    case "cycleLineStatus": {
      const order = findManualDeliveryOrder(command.orderId);
      if (!order) return true;
      const lines = (order.items || []).filter(line => line.key === command.lineKey);
      if (!lines.length) return true;
      const currentStatus = lines.every(line => line.kitchenStatus === "Completo")
        ? "Completo"
        : lines.some(line => line.kitchenStatus === "In preparazione") ? "In preparazione" : "Da preparare";
      const nextStatus = currentStatus === "In preparazione" ? "Completo" : currentStatus === "Completo" ? "Da preparare" : "In preparazione";
      lines.forEach(line => { line.kitchenStatus = nextStatus; });
      return true;
    }
    case "setNotes": {
      const order = findManualDeliveryOrder(command.orderId);
      if (!order) return true;
      order.notes = command.notes || "";
      return true;
    }
    case "addOrderLine": {
      const order = findManualDeliveryOrder(command.orderId);
      if (!order) return true;
      if (!Array.isArray(order.items)) order.items = [];
      const name = String(command.itemName || "").trim();
      const price = Number(command.itemPrice || 0);
      // Stesso formato di lineKey() nel frontend (course=1, nessuna variazione: i Pick-up
      // manuali non hanno sequenze/opzioni), cosi' un'interazione LAN successiva sulla stessa
      // riga la riconosce come la stessa voce invece di duplicarla.
      const key = `${command.itemId}::name=${name.toLowerCase()}::price=${price.toFixed(2)}::course=1::minus=::plus=`;
      const existing = order.items.find(line => line.key === key);
      if (existing) {
        existing.qty += 1;
      } else {
        order.items.push({
          id: command.itemId,
          key,
          name,
          originalName: name,
          category: command.itemCategory || "",
          price,
          minusVariations: [],
          plusVariations: [],
          lineNote: "",
          course: 1,
          splitAccount: "",
          qty: 1,
          sentQty: 0,
          noTurns: true
        });
      }
      order.occupied = true;
      order.kitchenClosed = false;
      if (order.status === "Servita") order.status = "Nuova";
      return true;
    }
    case "adjustOrderLineQty": {
      const order = findManualDeliveryOrder(command.orderId);
      if (!order || !Array.isArray(order.items)) return true;
      const line = order.items.find(item => item.key === command.lineKey);
      if (!line) return true;
      if (line.kitchenStatus === "Completo") return true;
      line.qty += Number(command.delta || 0);
      line.sentQty = Math.min(Number(line.sentQty || 0), Math.max(0, line.qty));
      order.items = order.items.filter(item => item.qty > 0);
      return true;
    }
    default:
      return true;
  }
}

// Legge dal remoto i comandi ancora non applicati, li applica alla copia locale autorevole e
// conferma quelli riusciti. Come il resto della sincronizzazione, non deve mai bloccare l'uso
// locale: un errore di rete si logga soltanto e si ritenta al giro successivo.
async function pollExternalCommands() {
  if (!RESTAURANT_SYNC_KEY || !sharedState) return;
  try {
    const listUrl = RESTAURANT_SYNC_URL + "?mode=pending_commands&key=" + encodeURIComponent(RESTAURANT_SYNC_KEY);
    const listResponse = await fetch(listUrl, { method: "GET" });
    if (!listResponse.ok) throw new Error("HTTP " + listResponse.status);
    const data = await listResponse.json();
    const pending = Array.isArray(data.commands) ? data.commands : [];
    if (!pending.length) return;

    const appliedIds = [];
    for (const entry of pending) {
      let command;
      try {
        command = JSON.parse(entry.command_json);
      } catch (error) {
        fs.appendFileSync(RESTAURANT_SYNC_LOG, `${new Date().toISOString()} comando illeggibile ${entry.client_command_id}: ${error.message}\n`);
        appliedIds.push(entry.client_command_id);
        continue;
      }
      if (applyExternalCommand(command)) appliedIds.push(entry.client_command_id);
    }
    if (appliedIds.length) {
      persistAndBroadcast();
      const ackUrl = RESTAURANT_SYNC_URL + "?mode=ack_commands&key=" + encodeURIComponent(RESTAURANT_SYNC_KEY);
      const ackResponse = await fetch(ackUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ client_command_ids: appliedIds })
      });
      if (!ackResponse.ok) throw new Error("HTTP " + ackResponse.status + " durante ack_commands");
    }
  } catch (error) {
    fs.appendFileSync(RESTAURANT_SYNC_LOG, `${new Date().toISOString()} pending_commands ${error.message}\n`);
  }
}

const server = http.createServer((request, response) => {
  if (request.method === "OPTIONS") {
    response.writeHead(204, { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "Content-Type" });
    return response.end();
  }
  if (request.url === "/api/state" && request.method === "GET") return sendJson(response, 200, { state: sharedState });
  if (request.url.startsWith("/api/table-lock") && request.method === "GET") {
    const query = new URL(request.url, "http://localhost").searchParams;
    const tableId = query.get("tableId");
    const current = tableId ? tableLocks.get(String(tableId)) : null;
    const now = Date.now();
    if (!current) return sendJson(response, 200, { locked: false, status: "libero" });
    if (current.expiresAt <= now) {
      current.status = "scaduto";
      return sendJson(response, 200, { locked: false, status: "scaduto", expiresAt: current.expiresAt });
    }
    return sendJson(response, 200, { locked: true, status: "attivo", expiresAt: current.expiresAt });
  }
  if (request.url === "/api/table-lock" && (request.method === "POST" || request.method === "DELETE")) {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", () => {
      try {
        const input = JSON.parse(body || "{}");
        const tableId = String(input.tableId || "");
        const token = String(input.token || "");
        if (!tableId || !token) return sendJson(response, 400, { ok: false, error: "tableId e token sono obbligatori" });
        const current = tableLocks.get(tableId);
        const now = Date.now();
        if (request.method === "DELETE") {
          if (current && current.token === token) tableLocks.delete(tableId);
          return sendJson(response, 200, { ok: true });
        }
        if (current && current.expiresAt > now) {
          if (current.token !== token) {
            return sendJson(response, 409, { ok: false, locked: true, status: "attivo", expiresAt: current.expiresAt });
          }
          current.status = "attivo";
          current.expiresAt = now + TABLE_LOCK_TTL_MS;
          return sendJson(response, 200, { ok: true, lockId: current.lockId, status: current.status, expiresAt: current.expiresAt });
        }
        if (current && current.expiresAt <= now) current.status = "scaduto";
        if (current && current.status === "scaduto" && current.token === token) {
          current.status = "attivo";
          current.expiresAt = now + TABLE_LOCK_TTL_MS;
          return sendJson(response, 200, { ok: true, lockId: current.lockId, status: current.status, expiresAt: current.expiresAt });
        }
        if (current) current.status = "decaduto";
        const lockId = "lease-" + Date.now() + "-" + Math.random().toString(36).slice(2, 10);
        tableLocks.set(tableId, { token, lockId, status: "attivo", expiresAt: now + TABLE_LOCK_TTL_MS });
        sendJson(response, 200, { ok: true, lockId, status: "attivo", expiresAt: now + TABLE_LOCK_TTL_MS });
      } catch (error) {
        sendJson(response, 400, { ok: false, error: "Lock non valido" });
      }
    });
    return;
  }
  if (request.method === "POST" && [
    "/api/deliveroo/webhooks/order-events",
    "/api/deliveroo/webhooks/rider-events",
    "/api/deliveroo/webhooks/menu-events"
  ].includes(request.url)) return handleDeliverooWebhook(request, response);
  if (request.url.startsWith("/api/reservations") && request.method === "POST") return handleReservationsProxy(request, response);
  if (request.url === "/api/sigonella/update-order" && request.method === "POST") {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", async () => {
      try {
        const input = JSON.parse(body || "{}");
        const order = input.order || {};
        const source = order.sigonellaPayload && typeof order.sigonellaPayload === "object"
          ? { ...order.sigonellaPayload }
          : {};
        const lines = Array.isArray(order.items) ? order.items : [];
        source.id = String(order.externalOrderId || source.external_order_id || source.id || "");
        source.external_order_id = source.id;
        if (!source.id) return sendJson(response, 400, { ok: false, error: "Ordine Sigonella senza id" });
        const originalItems = Array.isArray(source.items) ? source.items : [];
        source.items = lines.map(line => ({
          id: line.id,
          product_id: line.id,
          product_name: line.name || "",
          quantity: Math.max(1, Number(line.qty || 1)),
          price: Number(line.price || 0),
          subtotal: Number((Number(line.price || 0) * Number(line.qty || 0)).toFixed(2)),
          customer_notes: (originalItems.find(item => String(item.id || item.product_id || "") === String(line.id || "")) || {}).customer_notes || "",
          options: (originalItems.find(item => String(item.id || item.product_id || "") === String(line.id || "")) || {}).options || []
        }));
        source.total = Number(lines.reduce((sum, line) => sum + Number(line.price || 0) * Number(line.qty || 0), 0).toFixed(2));
        const upstream = await fetch(SIGONELLA_UPDATE_ORDER_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ form: source })
        });
        const text = await upstream.text();
        let result;
        try { result = JSON.parse(text); } catch (_) { result = { raw: text }; }
        if (!upstream.ok) return sendJson(response, 502, { ok: false, upstreamStatus: upstream.status, response: result });
        const wrapped = result && Object.prototype.hasOwnProperty.call(result, "d") ? result.d : result;
        let normalized = wrapped;
        if (typeof wrapped === "string") { try { normalized = JSON.parse(wrapped); } catch (_) {} }
        if (normalized && normalized.ok === false) return sendJson(response, 502, normalized);
        return sendJson(response, 200, normalized || { ok: true });
      } catch (error) {
        return sendJson(response, 502, { ok: false, error: error.message });
      }
    });
    return;
  }
  if (request.url === "/api/menu" && request.method === "GET") {
    loadSharedMenuCatalog()
      .then(() => sendJson(response, 200, sharedMenuPayload || []))
      .catch(error => sendJson(response, 502, {
        error: "Menu online non disponibile",
        detail: error.message,
        hint: "Verifica che il PC/server locale possa raggiungere https://servizi.thaiprincess.it"
      }));
    return;
  }
  if (request.url === "/api/hubrise/status" && request.method === "POST") {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", async () => {
      if (!HUBRISE_STATUS_KEY) return sendJson(response, 503, { error: "HUBRISE_STATUS_KEY non impostata" });
      try {
        const upstream = await fetch(HUBRISE_STATUS_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-HubRise-Status-Key": HUBRISE_STATUS_KEY },
          body
        });
        const text = await upstream.text();
        response.writeHead(upstream.status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
        response.end(text);
      } catch (error) {
        sendJson(response, 502, { error: "Aggiornamento stato HubRise non disponibile", detail: error.message });
      }
    });
    return;
  }
  if (request.url === "/api/log-freed" && request.method === "POST") {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", async () => {
      if (!RESTAURANT_SYNC_KEY) return sendJson(response, 503, { error: "RESTAURANT_SYNC_KEY non impostata" });
      try {
        const upstream = await fetch(RESTAURANT_SYNC_URL + "?mode=log_freed&key=" + encodeURIComponent(RESTAURANT_SYNC_KEY) +
          "&now=" + encodeURIComponent(localNowString()), {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body
        });
        const text = await upstream.text();
        response.writeHead(upstream.status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
        response.end(text);
      } catch (error) {
        sendJson(response, 502, { error: "Registro remoto non disponibile", detail: error.message });
      }
    });
    return;
  }
  if (request.url === "/api/operations" && request.method === "POST") {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", () => {
      try {
        const input = JSON.parse(body || "{}");
        const operation = String(input.operation || "");
        const payload = input.payload || {};
        if (operation === "get_state") return sendJson(response, 200, { ok: true, state: sharedState });
        if (!sharedState || !Array.isArray(sharedState.tables)) return sendJson(response, 503, { ok: false, error: "Stato sala non disponibile" });
        const expectedRevision = Number(payload.expectedRevision || 0);
        const currentRevision = Number(sharedState.stateRevision || 0);
        if (expectedRevision && expectedRevision !== currentRevision) return sendJson(response, 409, { ok: false, stale: true, state: sharedState });
        const tableId = Number(payload.tableId);
        const table = sharedState.tables.find(item => Number(item.id) === tableId);
        if (!table && operation !== "clear_reservation") return sendJson(response, 404, { ok: false, error: "Tavolo non trovato" });
        const reservationId = String(payload.reservationId || payload.reservation_id || "");
        const reservation = (sharedState.reservations || []).find(item => String(item.id || item.reservationId || "") === reservationId);
        if (!reservation && operation !== "open_table") return sendJson(response, 404, { ok: false, error: "Prenotazione non trovata" });
        if (operation === "open_table" && (table.occupied || (table.items || []).length)) return sendJson(response, 409, { ok: false, error: "Il tavolo contiene gia una comanda" });
        if (operation === "move_reservation" && (table.items || []).length) return sendJson(response, 409, { ok: false, error: "Il tavolo contiene articoli: spostare la comanda da Gestione Comande" });
        if (operation === "clear_reservation") {
          const clearTableIds = Array.isArray(payload.tableIds) ? payload.tableIds.map(Number) : [];
          sharedState.tables.forEach(item => {
            const tho = item.tho || {};
            const matchesReservation = String(tho.reservation_id || tho.seated_reservation_id || "") === reservationId;
            if (!matchesReservation && clearTableIds.indexOf(Number(item.id)) < 0) return;
            item.items = [];
            item.occupied = false;
            item.covers = 0;
            item.coversEnteredAt = null;
            item.status = "Libero";
            delete item.customer;
            item.tho = { ...tho };
            delete item.tho.reservation_id;
            delete item.tho.seated_reservation_id;
          });
          sharedState.stateRevision = currentRevision + 1;
          persistStateFiles();
          broadcast();
          return sendJson(response, 200, { ok: true, state: sharedState, stateRevision: sharedState.stateRevision });
        }
        if (operation === "open_table") {
          table.occupied = true;
          table.covers = Math.max(0, Number(payload.covers || 0));
          table.coversEnteredAt = new Date().toISOString();
          table.status = "Nuova";
          table.items = Array.isArray(table.items) ? table.items : [];
          table.tho = { ...(table.tho || {}), table_id: tableId, covers: table.covers };
          if (reservation && payload.reservationDecision === "same") {
            reservation.status = "seated";
            reservation.tableIds = [tableId];
            table.tho.seated_reservation_id = reservationId;
            table.tho.reservation_id = reservationId;
          } else {
            table.tho.source = "walk_in";
            table.tho.seated_reservation_id = "walkin-" + Date.now();
          }
        } else if (operation === "adopt_walkin" || operation === "move_reservation") {
          let previousIds = [];
          try { previousIds = Array.isArray(reservation.tableIds) ? reservation.tableIds : JSON.parse(reservation.notes || "[]"); } catch (error) { previousIds = []; }
          previousIds.map(Number).filter(Number.isFinite).forEach(previousId => {
            if (previousId === tableId) return;
            const previous = sharedState.tables.find(item => Number(item.id) === previousId);
            if (!previous || previous.items && previous.items.length) return;
            previous.occupied = false;
            previous.covers = 0;
            previous.coversEnteredAt = null;
            previous.status = "Nuova";
            if (previous.tho) {
              delete previous.tho.reservation_id;
              delete previous.tho.seated_reservation_id;
              delete previous.tho.reservation_start;
              delete previous.tho.reservation_status;
            }
            delete previous.customer;
          });
          reservation.tableIds = [tableId];
          reservation.status = "seated";
          table.occupied = true;
          table.status = "Nuova";
          table.tho = { ...(table.tho || {}), table_id: tableId, reservation_id: reservationId, seated_reservation_id: reservationId, table_status: "seduto" };
          if (operation === "adopt_walkin") table.tho.source = "reservation";
          table.customer = table.customer || {};
        } else {
          return sendJson(response, 400, { ok: false, error: "Operazione non riconosciuta" });
        }
        sharedState.stateRevision = currentRevision + 1;
        persistStateFiles();
        broadcast();
        return sendJson(response, 200, { ok: true, state: sharedState, stateRevision: sharedState.stateRevision });
      } catch (error) {
        return sendJson(response, 400, { ok: false, error: "Payload operativo non valido" });
      }
    });
    return;
  }
  if (request.url === "/api/state" && request.method === "POST") {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", () => {
      try {
        // Il browser invia sempre l'intero stato. Per deliveryOrders serve un merge, non una
        // sostituzione secca in nessuna delle due direzioni: gli ordini che il browser gia'
        // conosce vanno presi dalla sua versione (altrimenti si perderebbero azioni come "Manda
        // in cucina"), ma gli ordini arrivati dal polling DOPO l'ultimo stato noto al browser
        // vanno comunque preservati, altrimenti un salvataggio del browser li cancellerebbe.
        const parsedBody = JSON.parse(body);
        const incomingState = parsedBody.state || parsedBody;
        const resetDeliveryOrders = parsedBody.resetDeliveryOrders === true;
        const tableLock = parsedBody.tableLock;
        if (tableLock && tableLock.tableId && tableLock.token) {
          const currentLock = tableLocks.get(String(tableLock.tableId));
          if (!currentLock || currentLock.token !== String(tableLock.token) || currentLock.lockId !== String(tableLock.lockId) || currentLock.expiresAt <= Date.now()) {
            sendJson(response, 409, { ok: false, stale: true, lockExpired: true, error: "Il lock del tavolo non Ã¨ piÃ¹ valido" });
            return;
          }
        }
        const currentRevision = Number(sharedState && sharedState.stateRevision || 0);
        const incomingRevision = Number(incomingState.stateRevision || 0);
        if (currentRevision > 0 && incomingRevision < currentRevision) {
          sendJson(response, 409, { ok: false, stale: true, state: sharedState });
          return;
        }
        const previousDeliveryOrders = (sharedState && Array.isArray(sharedState.deliveryOrders)) ? sharedState.deliveryOrders : [];
        const previousFeedStatus = sharedState && sharedState.hubriseFeedStatus;
        const currentMenu = sharedState && sharedState.menu;
        sharedState = incomingState;
        if (!sharedState.menu && currentMenu) sharedState.menu = currentMenu;
        sharedState.stateRevision = Math.max(currentRevision, incomingRevision) + 1;
        if (resetDeliveryOrders) {
          sharedState.deliveryOrders = [];
        } else {
          const clientDeliveryOrders = Array.isArray(sharedState.deliveryOrders) ? sharedState.deliveryOrders : [];
          const clientOrderIds = new Set(clientDeliveryOrders.map(order => order.id));
          const serverOnlyOrders = previousDeliveryOrders.filter(order => !clientOrderIds.has(order.id));
          sharedState.deliveryOrders = [...clientDeliveryOrders, ...serverOnlyOrders];
        }
        if (previousFeedStatus !== undefined) sharedState.hubriseFeedStatus = previousFeedStatus;
        persistStateFiles();
        // Pubblica l'evento realtime solo dopo aver aggiornato lo snapshot remoto:
        // altrimenti il client remoto si sveglia, legge RestaurantSync e trova ancora
        // il valore precedente.
        pushStateSnapshot().finally(() => {
          broadcast();
          sendJson(response, 200, { ok: true });
        });
      } catch (error) {
        sendJson(response, 400, { error: "Stato non valido" });
      }
    });
    return;
  }
  if (request.url === "/api/print/test" && request.method === "POST") {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", async () => {
      try {
        const input = JSON.parse(body || "{}");
        const printer = input.printer && typeof input.printer === "object" ? input.printer : {};
        const host = String(input.host || input.printerHost || printer.host || "").trim();
        const port = Number(input.port || printer.port || 9100);
        if (!host || !/^[A-Za-z0-9.-]+$/.test(host)) return sendJson(response, 400, { ok: false, error: "Stampante non valida" });
        if (!Number.isInteger(port) || port < 1 || port > 65535) return sendJson(response, 400, { ok: false, error: "Porta non valida" });
        // Il frontend genera già il payload ESC/POS completo (inclusi i byte ESC/GS).
        // Manteniamo il fallback per chiamate manuali o vecchie versioni del client.
        const payload = input.payload || input.text || "TEST STAMPANTE\nEpson TM-T88VI\n" + host;
        const data = Buffer.isBuffer(payload)
          ? payload
          : Buffer.from(String(payload), "utf8");
        const result = await printEscPosRaw(host, port, data);
        fs.appendFileSync(PRINT_LOG, `${new Date().toISOString()} raw ${host}:${port} ${JSON.stringify(payload)}\n`);
        sendJson(response, 200, result);
      } catch (error) {
        sendJson(response, 502, { ok: false, error: error.message });
      }
    });
    return;
  }
  if (request.url === "/api/fiscal-printer/status" && request.method === "POST") {
    let body = "";
    request.on("data", chunk => {
      body += chunk;
      if (body.length > 16 * 1024) request.destroy();
    });
    request.on("end", async () => {
      try {
        const input = JSON.parse(body || "{}");
        const host = String(input.host || "").trim();
        const port = Number(input.port || 80);
        const devid = String(input.devid || "local_printer").trim();
        const operator = String(input.operator || "1").trim();
        if (!host || !/^[A-Za-z0-9.-]+$/.test(host)) {
          return sendJson(response, 400, { ok: false, error: "IP o nome host della stampante non valido" });
        }
        if (!Number.isInteger(port) || port < 1 || port > 65535) {
          return sendJson(response, 400, { ok: false, error: "Porta della stampante non valida" });
        }
        if (!devid || devid.length > 80 || !operator || operator.length > 20) {
          return sendJson(response, 400, { ok: false, error: "devid o operatore non valido" });
        }

        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 7000);
        try {
          const result = await epsonFiscal.queryPrinterStatus(host, {
            port,
            devid,
            operator,
            statusType: "1",
            timeoutMs: 5000,
            signal: controller.signal
          });
          return sendJson(response, 200, {
            ok: result.success,
            code: result.code,
            status: result.status,
            addInfo: result.addInfo,
            raw: result.raw,
            fiscalRequest: receipt,
            error: result.success ? "" : `La stampante ha risposto con codice ${result.code || "sconosciuto"}`
          });
        } finally {
          clearTimeout(timer);
        }
      } catch (error) {
        const message = error && error.name === "AbortError"
          ? "Timeout: la stampante non ha risposto entro 7 secondi"
          : `Stampante non raggiungibile: ${error.message}`;
        return sendJson(response, 502, { ok: false, error: message });
      }
    });
    return;
  }
  if (request.url === "/api/fiscal-printer/receipt" && request.method === "POST") {
    let body = "";
    let fiscalRequestStarted = false;
    request.on("data", chunk => {
      body += chunk;
      if (body.length > 128 * 1024) request.destroy();
    });
    request.on("end", async () => {
      try {
        const input = JSON.parse(body || "{}");
        const printer = sharedState && sharedState.settings && sharedState.settings.fiscalPrinter;
        if (!printer || printer.enabled !== true || !printer.host) {
          return sendJson(response, 409, { ok: false, error: "Stampante fiscale non abilitata o non configurata" });
        }
        const port = Number(printer.port || 80);
        const operator = String(printer.operator || "1");
        const requestedReceipt = {
          operator,
          items: input.items,
          payment: input.payment
        };
        const testModeOneCent = printer.testModeOneCent === true;
        const receipt = epsonFiscal.applyOneCentTestMode(requestedReceipt, {
          enabled: testModeOneCent,
          department: printer.defaultDepartment || "2"
        });
        // Valida il documento prima di segnare l'esito come potenzialmente incerto.
        // Dopo l'inizio della chiamata alla stampante non effettuiamo mai retry automatici.
        epsonFiscal.buildFiscalReceiptXml(receipt);
        if (fiscalReceiptInProgress) {
          return sendJson(response, 409, { ok: false, error: "Un altro scontrino fiscale Ã¨ giÃ  in emissione" });
        }
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 15000);
        try {
          fiscalReceiptInProgress = true;
          fiscalRequestStarted = true;
          const result = await epsonFiscal.printFiscalReceipt(printer.host, receipt, {
            port,
            devid: printer.devid || "local_printer",
            signal: controller.signal
          });
          return sendJson(response, result.success ? 200 : 502, {
            ok: result.success,
            testModeOneCent,
            fiscalAmount: result.addInfo && result.addInfo.fiscalReceiptAmount || (testModeOneCent ? "0,01" : ""),
            code: result.code,
            status: result.status,
            addInfo: result.addInfo,
            error: result.success ? "" : `La stampante ha risposto con codice ${result.code || "sconosciuto"}`
          });
        } finally {
          clearTimeout(timer);
          fiscalReceiptInProgress = false;
        }
      } catch (error) {
        const message = error && error.name === "AbortError"
          ? "Timeout durante l'emissione: verificare la stampante prima di riprovare"
          : error.message;
        return sendJson(response, 502, {
          ok: false,
          outcomeUncertain: fiscalRequestStarted,
          error: message
        });
      }
    });
    return;
  }
  if (request.url === "/api/events" && request.method === "GET") {
    response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Connection": "keep-alive", "Access-Control-Allow-Origin": "*" });
    response.write("retry: 2000\n\n");
    clients.add(response);
    request.on("close", () => clients.delete(response));
    return;
  }
  if (request.url === "/api/print/raw" && request.method === "POST") {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", async () => {
      try {
        const input = JSON.parse(body || "{}");
        const printer = input.printer && typeof input.printer === "object" ? input.printer : {};
        const host = String(input.host || printer.host || "").trim();
        const port = Number(input.port || printer.port || 9100);
        const payload = String(input.payload || input.text || "");
        if (!host || !/^[A-Za-z0-9.-]+$/.test(host)) return sendJson(response, 400, { ok: false, error: "Stampante non valida" });
        if (!Number.isInteger(port) || port < 1 || port > 65535) return sendJson(response, 400, { ok: false, error: "Porta non valida" });
        if (!payload) return sendJson(response, 400, { ok: false, error: "Contenuto di stampa vuoto" });
        const result = await printEscPosRaw(host, port, payload);
        fs.appendFileSync(PRINT_LOG, `${new Date().toISOString()} raw ${host}:${port} ${JSON.stringify(input.job || "document") }\n`);
        return sendJson(response, 200, result);
      } catch (error) {
        fs.appendFileSync(PRINT_LOG, `${new Date().toISOString()} ERROR ${error.stack || error}\n`);
        return sendJson(response, 502, { ok: false, error: String(error.message || error) });
      }
    });
    return;
  }
  if (request.url === "/api/print/preconto-graphic" && request.method === "POST") {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", async () => {
      try {
        const input = JSON.parse(body || "{}");
        const printer = input.printer && typeof input.printer === "object" ? input.printer : {};
        if (!printer.host) return sendJson(response, 400, { ok: false, error: "Stampante non configurata" });
        if (!printGraphicPreconto) ({ printGraphicPreconto } = require("./src/graphic-preconto.js"));
        const result = await printGraphicPreconto(input.order || {}, printer, input.settings || {});
        return sendJson(response, 200, { ok: true, ...result });
      } catch (error) {
        return sendJson(response, 502, { ok: false, error: String(error.message || error) });
      }
    });
    return;
  }
  if ((request.url === "/reservations" || request.url === "/reservations/" || request.url === "/ReservationsNew") && request.method === "GET") {
    if (!REALTIME_KEY) return sendJson(response, 503, { ok: false, error: "REALTIME_KEY non configurata" });
    const target = new URL(RESERVATIONS_REMOTE_URL);
    target.searchParams.set("key", REALTIME_KEY);
    response.writeHead(302, { Location: target.toString(), "Cache-Control": "no-store" });
    return response.end();
  }
  if (request.url === "/api/version" && request.method === "GET") {
    return sendJson(response, 200, { version: APP_VERSION, packageVersion: require("./package.json").version });
  }
  if (request.url === "/api/admin/update" && request.method === "POST") {
    if (!updateAuthorized(request)) return sendJson(response, 401, { ok: false, error: "Chiave aggiornamento non valida" });
    if (updateInProgress) return sendJson(response, 409, { ok: false, error: "Aggiornamento già in corso" });
    updateInProgress = true;
    return runUpdateScript().then(output => {
      updateInProgress = false;
      sendJson(response, 200, { ok: true, output, restartScheduled: true });
      scheduleServiceRestart();
    }).catch(error => {
      updateInProgress = false;
      sendJson(response, 500, { ok: false, error: error.message });
    });
  }
  const requestPath = request.url.split("?")[0];
  const requested = requestPath === "/" ? "/outputs/gestione-comande-ristorante.html" : requestPath;
  const file = path.normalize(path.join(ROOT, requested));
  if (!file.startsWith(ROOT) || !fs.existsSync(file)) return sendJson(response, 404, { error: "Risorsa non trovata" });
  response.writeHead(200, { "Content-Type": file.endsWith(".html") ? "text/html; charset=utf-8" : "text/plain" });
  fs.createReadStream(file).pipe(response);
});

if (HOST) server.listen(PORT, HOST, () => console.log(`Ristorante disponibile su http://${HOST}:${PORT}`));
else server.listen(PORT, () => console.log(`Ristorante disponibile su http://localhost:${PORT}`));

connectRealtimeBridge();

if (HUBRISE_FEED_KEY) {
  pollHubRiseOrders();
  setInterval(pollHubRiseOrders, HUBRISE_POLL_INTERVAL_MS);
} else {
  console.log("HUBRISE_FEED_KEY non impostata: polling ordini HubRise disattivato.");
}

pollSigonellaOrders();
setInterval(pollSigonellaOrders, SIGONELLA_ORDERS_INTERVAL_MS);

if (RESTAURANT_SYNC_KEY) {
  pushStateSnapshot();
  pollExternalCommands();
  setInterval(pushStateSnapshot, RESTAURANT_SYNC_INTERVAL_MS);
  setInterval(pollExternalCommands, RESTAURANT_SYNC_INTERVAL_MS);
} else {
  console.log("RESTAURANT_SYNC_KEY non impostata: sincronizzazione istanza esterna disattivata.");
}

