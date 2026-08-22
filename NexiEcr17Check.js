// Verifica passiva: il terminale Nexi risponde su IP:porta per ECR17/37?
// Non invia nessun comando protocollo — solo apertura TCP e ascolto per qualche secondo.
// Uso: node NexiEcr17Check.js <ip> [porta] [secondi_ascolto]

const net = require('net');

const host = process.argv[2];
const port = parseInt(process.argv[3] || '1000', 10);
const listenSeconds = parseInt(process.argv[4] || '5', 10);

if (!host) {
  console.error('Uso: node NexiEcr17Check.js <ip> [porta=1000] [secondi_ascolto=5]');
  process.exit(1);
}

console.log(`Provo connessione TCP a ${host}:${port} ...`);

const socket = new net.Socket();
const startedAt = Date.now();
let received = Buffer.alloc(0);

socket.setTimeout(5000);

socket.on('connect', () => {
  console.log(`OK: connesso in ${Date.now() - startedAt} ms. In ascolto per ${listenSeconds}s (nessun dato inviato)...`);
  setTimeout(() => {
    if (received.length > 0) {
      console.log(`Ricevuti ${received.length} byte non richiesti dal terminale:`);
      console.log('  hex :', received.toString('hex'));
      console.log('  ascii:', JSON.stringify(received.toString('latin1')));
    } else {
      console.log('Nessun dato ricevuto spontaneamente (normale per molti ECR: restano in attesa di un comando).');
    }
    socket.destroy();
    process.exit(0);
  }, listenSeconds * 1000);
});

socket.on('data', (chunk) => {
  received = Buffer.concat([received, chunk]);
});

socket.on('timeout', () => {
  console.log('TIMEOUT: nessuna risposta di connessione entro 5s (porta filtrata o terminale non raggiungibile).');
  socket.destroy();
  process.exit(1);
});

socket.on('error', (err) => {
  if (err.code === 'ECONNREFUSED') {
    console.log('RIFIUTATA: il terminale risponde ma nulla ascolta su questa porta -> ECR17 probabilmente NON abilitato su questa porta.');
  } else {
    console.log(`ERRORE: ${err.code || err.message}`);
  }
  process.exit(1);
});

socket.connect(port, host);
