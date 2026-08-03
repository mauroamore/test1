const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || undefined; // undefined = tutte le interfacce (serve ai palmari in LAN)
const ROOT = __dirname;
const STATE_FILE = path.join(ROOT, "ristorante-state.json");
const PRINT_LOG = path.join(ROOT, "print-simulation.log");
const DELIVEROO_WEBHOOK_LOG = path.join(ROOT, "deliveroo-webhook.log");
const HUBRISE_FEED_LOG = path.join(ROOT, "hubrise-feed.log");
const HUBRISE_FEED_URL = process.env.HUBRISE_FEED_URL || "https://thaiprincess.it/HubRiseOrdersFeed.ashx";
const HUBRISE_FEED_KEY = process.env.HUBRISE_FEED_KEY || "";
const HUBRISE_POLL_INTERVAL_MS = Number(process.env.HUBRISE_POLL_INTERVAL_MS || 20000);
const HUBRISE_STATUS_URL = process.env.HUBRISE_STATUS_URL || "https://thaiprincess.it/HubRiseOrderStatus.ashx";
const HUBRISE_STATUS_KEY = process.env.HUBRISE_STATUS_KEY || "";
const RESTAURANT_SYNC_LOG = path.join(ROOT, "restaurant-sync.log");
const RESTAURANT_SYNC_URL = process.env.RESTAURANT_SYNC_URL || "https://thaiprincess.it/RestaurantSync.ashx";
const RESTAURANT_SYNC_KEY = process.env.RESTAURANT_SYNC_KEY || "";
const RESTAURANT_SYNC_INTERVAL_MS = Number(process.env.RESTAURANT_SYNC_INTERVAL_MS || 5000);
const clients = new Set();
const tableLocks = new Map();
const TABLE_LOCK_TTL_MS = 15000;
let sharedState = fs.existsSync(STATE_FILE) ? JSON.parse(fs.readFileSync(STATE_FILE, "utf8")) : null;
if (sharedState && !Number.isFinite(Number(sharedState.stateRevision))) sharedState.stateRevision = 1;

function sendJson(response, status, body) {
  response.writeHead(status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
  response.end(JSON.stringify(body));
}

function broadcast() {
  for (const response of clients) response.write(`data: ${JSON.stringify({ type: "state-updated" })}\n\n`);
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

function mergeDeliveryOrders(newOrders) {
  if (!sharedState) return;
  if (!Array.isArray(sharedState.deliveryOrders)) sharedState.deliveryOrders = [];
  for (const order of newOrders) {
    const index = sharedState.deliveryOrders.findIndex(existing => existing.id === order.id);
    if (index >= 0) sharedState.deliveryOrders[index] = order;
    else sharedState.deliveryOrders.push(order);
  }
}

function setHubRiseFeedStatus(ok, error) {
  if (!sharedState) return;
  sharedState.hubriseFeedStatus = { ok, error: error || null, checkedAt: new Date().toISOString() };
}

function persistAndBroadcast() {
  if (!sharedState) return;
  fs.writeFileSync(STATE_FILE, JSON.stringify(sharedState, null, 2));
  broadcast();
}

// Non deve mai bloccare o interrompere il server locale: qualunque errore di rete
// viene solo loggato, il prossimo giro di polling riprova da solo.
async function pollHubRiseOrders() {
  if (!HUBRISE_FEED_KEY) return;
  try {
    const url = HUBRISE_FEED_URL + "?key=" + encodeURIComponent(HUBRISE_FEED_KEY);
    const response = await fetch(url, { method: "GET" });
    if (!response.ok) throw new Error("HTTP " + response.status);
    const result = await response.json();
    if (result && result.state) {
      sharedState = result.state;
      sharedState.stateRevision = Number(sharedState.stateRevision || 0) + 1;
      fs.writeFileSync(STATE_FILE, JSON.stringify(sharedState, null, 2));
      broadcast();
    }
    const data = await response.json();
    const orders = Array.isArray(data.orders) ? data.orders : [];
    if (orders.length) {
      mergeDeliveryOrders(orders.map(order => ({
        id: order.external_order_id,
        source: "hubrise",
        customerName: order.customer_name,
        serviceType: order.service_type,
        status: order.status,
        total: order.total,
        currency: order.currency,
        collectionCode: order.collection_code,
        channel: order.channel,
        items: order.items || [],
        receivedAt: order.received_at,
        // Righe in formato compatibile col monitor cucina (stesso usato per i tavoli), cosi'
        // l'operatore puo' mandare l'ordine delivery in cucina come un ordine qualunque.
        lines: (order.items || []).map((item, index) => ({
          key: `hubrise-${order.external_order_id}-${index}`,
          name: item.name,
          category: item.category || "",
          price: item.unit_price || 0,
          qty: Number(item.quantity) || 1,
          sentQty: 0,
          course: 1,
          noTurns: true,
          kitchenStatus: undefined,
          minusVariations: [],
          plusVariations: [],
          lineNote: (item.options || []).map(option => option.name).filter(Boolean).join(", ")
        })),
        selectedCourse: 1,
        activeCourse: 1,
        kitchenClosed: false
      })));
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
      body: JSON.stringify(sharedState)
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
          lines: [],
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
      const lines = Array.isArray(command.lines) ? command.lines : [];
      order.lines = lines.map(item => {
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
    case "sendToKitchen": {
      const order = findManualDeliveryOrder(command.orderId);
      if (!order) return true;
      (order.lines || []).forEach(line => { line.sentQty = Math.max(0, Number(line.qty || 0)); });
      order.status = "Preparazione";
      return true;
    }
    case "cycleLineStatus": {
      const order = findManualDeliveryOrder(command.orderId);
      if (!order) return true;
      const lines = (order.lines || []).filter(line => line.key === command.lineKey);
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
      if (!Array.isArray(order.lines)) order.lines = [];
      const name = String(command.itemName || "").trim();
      const price = Number(command.itemPrice || 0);
      // Stesso formato di lineKey() nel frontend (course=1, nessuna variazione: i Pick-up
      // manuali non hanno sequenze/opzioni), cosi' un'interazione LAN successiva sulla stessa
      // riga la riconosce come la stessa voce invece di duplicarla.
      const key = `${command.itemId}::name=${name.toLowerCase()}::price=${price.toFixed(2)}::course=1::minus=::plus=`;
      const existing = order.lines.find(line => line.key === key);
      if (existing) {
        existing.qty += 1;
      } else {
        order.lines.push({
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
      if (!order || !Array.isArray(order.lines)) return true;
      const line = order.lines.find(item => item.key === command.lineKey);
      if (!line) return true;
      if (line.kitchenStatus === "Completo") return true;
      line.qty += Number(command.delta || 0);
      line.sentQty = Math.min(Number(line.sentQty || 0), Math.max(0, line.qty));
      order.lines = order.lines.filter(item => item.qty > 0);
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
  if (request.url === "/api/menu" && request.method === "GET") {
    fetch("https://thaiprincess.it/MenuService.asmx/GetMenu", { method: "GET" })
      .then(result => result.text())
      .then(xml => {
        const match = xml.match(/<string[^>]*>([\s\S]*?)<\/string>/i);
        if (!match) throw new Error("Risposta menu non valida");
        const json = match[1]
          .replace(/&quot;/g, '"')
          .replace(/&apos;/g, "'")
          .replace(/&lt;/g, "<")
          .replace(/&gt;/g, ">")
          .replace(/&amp;/g, "&");
        sendJson(response, 200, JSON.parse(json));
      })
      .catch(error => sendJson(response, 502, {
        error: "Menu online non disponibile",
        detail: error.message,
        hint: "Verifica che il PC/server locale possa raggiungere https://thaiprincess.it"
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
        const tableLock = parsedBody.tableLock;
        if (tableLock && tableLock.tableId && tableLock.token) {
          const currentLock = tableLocks.get(String(tableLock.tableId));
          if (!currentLock || currentLock.token !== String(tableLock.token) || currentLock.lockId !== String(tableLock.lockId) || currentLock.expiresAt <= Date.now()) {
            sendJson(response, 409, { ok: false, stale: true, lockExpired: true, error: "Il lock del tavolo non è più valido" });
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
        sharedState = incomingState;
        sharedState.stateRevision = Math.max(currentRevision, incomingRevision) + 1;
        const clientDeliveryOrders = Array.isArray(sharedState.deliveryOrders) ? sharedState.deliveryOrders : [];
        const clientOrderIds = new Set(clientDeliveryOrders.map(order => order.id));
        const serverOnlyOrders = previousDeliveryOrders.filter(order => !clientOrderIds.has(order.id));
        sharedState.deliveryOrders = [...clientDeliveryOrders, ...serverOnlyOrders];
        if (previousFeedStatus !== undefined) sharedState.hubriseFeedStatus = previousFeedStatus;
        fs.writeFileSync(STATE_FILE, JSON.stringify(sharedState, null, 2));
        broadcast();
        sendJson(response, 200, { ok: true });
      } catch (error) {
        sendJson(response, 400, { error: "Stato non valido" });
      }
    });
    return;
  }
  if (request.url === "/api/print/test" && request.method === "POST") {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", () => {
      fs.appendFileSync(PRINT_LOG, `${new Date().toISOString()} ${body}\n`);
      sendJson(response, 200, { ok: true, simulated: true });
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
  const requestPath = request.url.split("?")[0];
  const requested = requestPath === "/" ? "/outputs/gestione-comande-ristorante.html" : requestPath;
  const file = path.normalize(path.join(ROOT, requested));
  if (!file.startsWith(ROOT) || !fs.existsSync(file)) return sendJson(response, 404, { error: "Risorsa non trovata" });
  response.writeHead(200, { "Content-Type": file.endsWith(".html") ? "text/html; charset=utf-8" : "text/plain" });
  fs.createReadStream(file).pipe(response);
});

if (HOST) server.listen(PORT, HOST, () => console.log(`Ristorante disponibile su http://${HOST}:${PORT}`));
else server.listen(PORT, () => console.log(`Ristorante disponibile su http://localhost:${PORT}`));

if (HUBRISE_FEED_KEY) {
  pollHubRiseOrders();
  setInterval(pollHubRiseOrders, HUBRISE_POLL_INTERVAL_MS);
} else {
  console.log("HUBRISE_FEED_KEY non impostata: polling ordini HubRise disattivato.");
}

if (RESTAURANT_SYNC_KEY) {
  pushStateSnapshot();
  pollExternalCommands();
  setInterval(pushStateSnapshot, RESTAURANT_SYNC_INTERVAL_MS);
  setInterval(pollExternalCommands, RESTAURANT_SYNC_INTERVAL_MS);
} else {
  console.log("RESTAURANT_SYNC_KEY non impostata: sincronizzazione istanza esterna disattivata.");
}
