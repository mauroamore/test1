const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");

const root = __dirname;
const port = Number(process.env.RESERVATIONS_LAUNCHER_PORT || 8011);
const remoteUrl = process.env.RESERVATIONS_REMOTE_URL || "https://servizi.thaiprincess.it/ReservationsNew.html";

function loadDotEnv() {
  const file = path.join(root, ".env");
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/i);
    if (!match || process.env[match[1]]) continue;
    process.env[match[1]] = match[2].replace(/^['"]|['"]$/g, "");
  }
}

loadDotEnv();

const key = process.env.REALTIME_KEY || process.env.RESTAURANT_SYNC_KEY || "";
if (!key) {
  console.error("REALTIME_KEY o RESTAURANT_SYNC_KEY non configurata nel file .env");
  process.exit(1);
}

const target = new URL(remoteUrl);
target.searchParams.set("key", key);

const server = http.createServer((request, response) => {
  if (request.url !== "/" && request.url !== "/ReservationsNewLauncher") {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }
  response.writeHead(302, {
    Location: target.toString(),
    "Cache-Control": "no-store"
  });
  response.end();
});

server.listen(port, "127.0.0.1", () => {
  console.log(`ReservationsNew launcher: http://127.0.0.1:${port}/`);
  console.log(`Redirect: ${remoteUrl}`);
});
