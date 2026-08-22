# Integrazione HubRise

Integrazione indipendente da Deliveroo (nessun file/tabella condiviso), per ricevere ordini da HubRise
(che a sua volta aggrega Deliveroo, JustEat, UberEats ecc.) e farli arrivare fino alla schermata comande
locale, con un sync manuale del catalogo/menu verso HubRise e l'aggiornamento di stato ordine
(ricevuto/accettato/pronto per il ritiro) verso HubRise.

## 1. Schema database

Eseguire, in ordine, sul database MySQL configurato in `MySqlConnectionString`:

1. `HubRiseConnection.sql`
2. `HubRiseWebhook.sql`
3. `HubRiseOrders.sql`
4. `HubRiseProcessLog.sql`

## 2. Configurazione `web.config`

Aggiungere dentro `<appSettings>` (nessun segreto qui sotto, sono solo i nomi delle chiavi da valorizzare):

```xml
<add key="HubRiseApiBaseUrl" value="https://api.hubrise.com/v1" />
<add key="HubRiseManagerBaseUrl" value="https://manager.hubrise.com" />
<add key="HubRiseClientId" value="246634048027.clients.hubrise.com" />
<add key="HubRiseClientSecret" value="0898b697838e695bd6b69c4ee8fc7c968bad78824a64145456c4c36b8c7d0f77"/>
<add key="HubRiseScope" value="location[orders.write,customer_list.write,catalog.write]" />
<add key="HubRiseRedirectUri" value="urn:ietf:wg:oauth:2.0:oob" />
<add key="HubRiseConnectKey" value="0898b697838e695bd6b69c4ee8fc7c968" />
<add key="HubRiseWebhookSecret" value="0898b697838e695bd6b69c4ee8fc7c968" />
<add key="HubRiseDiagnosticsKey" value="0898b697838e695bd6b69c4ee8fc7c968" />
<add key="HubRiseOrdersFeedKey" value="0898b697838e695bd6b69c4ee8fc7c968" />
<add key="HubRiseMonitorKey" value="0898b697838e695bd6b69c4ee8fc7c968" />
<add key="HubRiseCatalogSyncKey" value="0898b697838e695bd6b69c4ee8fc7c968" />
<add key="HubRiseOrderStatusKey" value="UNA_SETTIMA_CHIAVE_CASUALE" />
```

**Importante**: lo scope sopra include `catalog.write`, aggiunto ora per il sync del menu. La
connessione OAuth gia' stabilita in precedenza (con lo scope senza `catalog.write`) non ha questo
permesso: va rifatta (vedi sezione 3 - revocare con `revoke=1` e ricollegare) prima di poter
caricare il catalogo, altrimenti `HubRiseCatalogSync.ashx?mode=upload` rispondera' con un errore
di permessi.

`HubRiseClientId`/`HubRiseClientSecret` si ottengono creando un OAuth client gratuito da
Settings > Developer nel back office HubRise (basta un account HubRise gratuito, nessuna
approvazione richiesta per iniziare a sviluppare/testare).

## 3. Connessione OAuth (una tantum)

1. Aprire `https://thaiprincess.it/HubRiseConnect.ashx?key=UNA_CHIAVE_LUNGA_CASUALE` (senza `code`)
   in un browser: reindirizza direttamente alla pagina di autorizzazione HubRise.
   (Per ottenere l'URL come JSON invece del redirect, aggiungere `&format=json`.)
2. Autorizzare l'accesso sul sito HubRise; verra' mostrato un codice da copiare.
3. Richiamare `https://thaiprincess.it/HubRiseConnect.ashx?key=...&code=IL_CODICE_MOSTRATO`:
   scambia il codice per un token e salva la connessione (`hubrise_connection`).
4. Per revocare: `https://thaiprincess.it/HubRiseConnect.ashx?key=...&revoke=1`.

Il token HubRise non scade: questo passaggio si ripete solo se la connessione viene revocata o
se si vuole ricollegare un account/location diverso.

## 4. Registrare il webhook ordini su HubRise

HubRise non ha una schermata nel back office per questo: la registrazione si fa con una chiamata
API (`POST /callback`), autenticata col token gia' ottenuto al passo 3. Basta aprire (dopo aver
completato la connessione OAuth):

`https://thaiprincess.it/HubRiseConnect.ashx?key=UNA_CHIAVE_LUNGA_CASUALE&register_webhook=1`

Registra automaticamente come callback `https://thaiprincess.it/HubRiseWebhook.ashx?wh=...` con
filtro eventi `{"order": ["create","update"]}`. HubRise firma comunque ogni webhook con l'header
`X-HubRise-Hmac-SHA256` (HMAC-SHA256 del corpo grezzo, chiave = `HubRiseClientSecret`), verificato
automaticamente da `HubRiseWebhook.ashx` in aggiunta al segreto nell'URL. Per ruotare il segreto
nell'URL: generare un nuovo `HubRiseWebhookSecret` e rilanciare `register_webhook=1`.

Verifica rapida stato integrazione (conteggi ordini/webhook):
`https://thaiprincess.it/HubRiseWebhook.ashx?diagnostics=1&key=UNA_TERZA_CHIAVE_CASUALE`

## 5. Far comparire gli ordini sulla schermata comande

Il processo locale `server.js` interroga periodicamente `HubRiseOrdersFeed.ashx` (ogni ~20s) e
mostra i nuovi ordini nel pannello "Ordini Delivery" della schermata comande via SSE. Per attivarlo,
impostare sulla macchina che esegue `server.js`:

```powershell
$env:HUBRISE_FEED_KEY = "UNA_QUARTA_CHIAVE_CASUALE"
$env:HUBRISE_FEED_URL = "https://thaiprincess.it/HubRiseOrdersFeed.ashx"
$env:HUBRISE_STATUS_KEY = "UNA_SETTIMA_CHIAVE_CASUALE"
$env:HUBRISE_STATUS_URL = "https://thaiprincess.it/HubRiseOrderStatus.ashx"
node server.js
```

Se `HUBRISE_FEED_KEY` non e' impostata, il polling resta disattivato (nessun errore, solo un
messaggio in console). Se la rete cade, il polling fallisce in silenzio e riprova al giro
successivo: la gestione tavoli locale non viene mai bloccata da questo. Senza
`HUBRISE_STATUS_KEY`, l'aggiornamento di stato verso HubRise (sezione 8) fallisce in silenzio allo
stesso modo, senza bloccare l'uso locale.

## 6. Postazione di controllo esterna

Da qualunque dispositivo fuori dalla rete del ristorante, aprire:

`https://thaiprincess.it/HubRiseMonitor.html?key=UNA_QUINTA_CHIAVE_CASUALE`

Mostra ordini e ultimi webhook in sola lettura (nessun dato modificato), utile per verificare da
remoto che l'integrazione stia funzionando.

## 7. Sync catalogo/menu verso HubRise

Manuale, mai automatico (per non rischiare di rompere il menu su tutte le piattaforme collegate
con un caricamento sbagliato). Sorgente: le stesse tabelle `v2_categories`/`v2_products` usate da
`MenuService.asmx`, filtrate su `is_active = 1 AND is_delivery = 1`. Ogni prodotto ha una sola SKU
(nessuna variante/opzione a pagamento: gli "ingredienti" in questo gestionale sono solo
informativi). Ref code deterministici (`C{id}` per le categorie, `P{id}` per i prodotti/SKU): non
serve una tabella di mapping, il collegamento con l'id locale si ricostruisce dal ref stesso.

1. Anteprima (nessuna chiamata verso HubRise):
   `https://thaiprincess.it/HubRiseCatalogSync.ashx?mode=preview&key=UNA_SESTA_CHIAVE_CASUALE`
2. Controllare che il JSON restituito corrisponda al menu reale.
3. Caricamento effettivo (richiede lo scope `catalog.write`, vedi nota sopra):
   `https://thaiprincess.it/HubRiseCatalogSync.ashx?mode=upload&key=UNA_SESTA_CHIAVE_CASUALE`
4. Verificare il risultato con **Catalog Manager** (una delle app HubRise gia' viste in
   CONNECTIONS > View available apps) o rileggendo il catalogo via API.

Fuori scope in questo giro: caricamento immagini prodotto (HubRise le richiede con una chiamata
separata, `POST /catalogs/:id/images`) e qualunque opzione/variante a pagamento.

## 8. Aggiornamento di stato ordine verso HubRise

Nessun aggiornamento automatico oltre alla conferma di ricezione. Mappatura:

- **Ricezione webhook** (`HubRiseWebhook.ashx`, automatico): se tutti i `sku_ref` degli articoli
  corrispondono a prodotti reali e attivi del catalogo (`v2_products`), conferma subito a HubRise
  `status=received` ("arrivato", non "accettato"). Se anche un solo articolo ha un ref non
  riconosciuto, non conferma nulla e scrive un WARN in `hubrise_process_log` per verifica manuale.
- **"Manda in cucina"** (pannello o modale): un prompt chiede tra quanti minuti sara' pronto
  l'ordine (lasciare vuoto per non modificare l'orario proposto dalla piattaforma); poi
  `status=accepted` e subito dopo `status=in_preparation` con `confirmed_time` valorizzato se
  indicato. Vale solo per gli ordini realmente arrivati da HubRise (i Pick-up manuali non hanno
  nulla da sincronizzare, non esistono su HubRise).
- **"Consegnato"** (kitchen monitor o modale): `status=awaiting_collection` ("pronto per il
  ritiro" — corretto sia per pick-up che per consegna, e' poi la piattaforma a segnare l'effettiva
  consegna).

Il browser non chiama mai HubRise direttamente: passa da un endpoint locale di `server.js`
(`/api/hubrise/status`) che inoltra a `HubRiseOrderStatus.ashx` tenendo la chiave lato server (va
impostata `HUBRISE_STATUS_KEY`, vedi sezione 5). Se HubRise non risponde, l'aggiornamento locale
dell'ordine non viene bloccato: si perde solo la sincronizzazione dello stato lato HubRise per
quella transizione.

## 9. Sincronizzazione con un'istanza esterna del software

Indipendente da HubRise (nessuna tabella condivisa): permette a un dispositivo fuori dalla rete
del ristorante di vedere tutta la situazione interna (tavoli, comande, monitor cucina, pannello
Delivery & Pick-up) e di agire **solo** sugli ordini Pick-up creati manualmente (`source:
"manual"`), mai su tavoli o ordini HubRise. Il locale (`server.js`) resta sempre l'unica fonte
autorevole.

1. Eseguire `RestaurantSync.sql` sul database (crea `restaurant_state_snapshot` e
   `restaurant_command_queue`).
2. Aggiungere in `web.config`:
   ```xml
   <add key="RestaurantSyncKey" value="UN'OTTAVA_CHIAVE_LUNGA_CASUALE" />
   ```
3. Caricare `RestaurantSync.ashx` sul sito.
4. Sulla macchina che esegue `server.js`, impostare:
   ```powershell
   $env:RESTAURANT_SYNC_URL = "https://thaiprincess.it/RestaurantSync.ashx"
   $env:RESTAURANT_SYNC_KEY = "UN'OTTAVA_CHIAVE_LUNGA_CASUALE"
   node server.js
   ```
   Senza `RESTAURANT_SYNC_KEY`, la sincronizzazione esterna resta disattivata (nessun errore,
   solo un messaggio in console); come per HubRise, un errore di rete si logga in
   `restaurant-sync.log` e si ritenta al giro successivo, senza mai bloccare l'uso locale.
5. Caricare anche `outputs/gestione-comande-ristorante.html` sul sito (stesso file usato in LAN).
   Da un dispositivo fuori dalla rete del ristorante, aprire:
   `https://thaiprincess.it/outputs/gestione-comande-ristorante.html?key=UN'OTTAVA_CHIAVE_LUNGA_CASUALE`

   (la sola presenza di `key` nell'URL attiva la modalita' esterna: non serve nessun altro
   parametro, l'URL in LAN non ha mai una `key`).

   In questa modalita' la pagina legge lo stato da `RestaurantSync.ashx` ogni ~5s (niente SSE) e
   mostra una striscia in alto con lo stato dei comandi inviati ("in attesa" → "confermato" entro
   qualche secondo, oppure "non ancora raggiunto il ristorante" se il locale non risponde entro
   ~40s). Tavoli e ordini HubRise sono di sola lettura; sui Pick-up manuali restano disponibili:
   crearne uno nuovo (bottone "+"), aggiungere piatti dal menu, aumentare/diminuire la quantita'
   di un piatto gia' aggiunto, mandarlo in cucina ("Invia"), far scorrere lo stato di un piatto
   sul monitor cucina, scrivere una nota. Restano solo-LAN: "Pronta"/"Consegnato" (segnare un
   ordine pronto o consegnato/chiudere la comanda resta una decisione presa in sala), variazioni
   /ingredienti (bottone "Apri variazioni"), rinominare/cambiare prezzo di una riga, tavoli e
   ordini HubRise.

   Un Pick-up appena creato da remoto resta puramente locale (nome, orario, piatti aggiunti,
   nota) finche' non viene mandato in cucina: solo a quel punto arriva al locale autorevole, in
   un'unica trasmissione (niente comandi separati per ogni piatto aggiunto durante la
   composizione). Se annullato prima dell'invio, non lascia nessuna traccia sul locale.

   "Invia" (locale e remoto) e' attivo solo se c'e' davvero qualcosa di nuovo da mandare in
   cucina rispetto all'ultimo invio (una riga con quantita' non ancora inviata): evita reinvii a
   vuoto quando non e' cambiato nulla dall'ultima volta.

   Il modale tavolo/Pick-up ha anche un bottone "Libera tavolo", visibile e utilizzabile solo
   dal Master (sempre disattivato da remoto): libera il tavolo (torna disponibile, senza finire
   nello Storico ordini locale) o scarta un Pick-up manuale. L'evento non sparisce del tutto pero':
   viene registrato in modo permanente in una tabella del database remoto
   (`restaurant_freed_log` - tipo, id, etichetta, contenuto al momento della liberazione, data/ora),
   tramite `server.js` (`POST /api/log-freed`, che inoltra a `RestaurantSync.ashx?mode=log_freed`
   tenendo `RESTAURANT_SYNC_KEY` lato server). Nessuna pagina di consultazione per ora: si
   interroga con una query diretta se serve un controllo.

## 10. Pagina per palmari

Stesso file (`gestione-comande-ristorante.html`), stessa sincronizzazione LAN di sempre
(`/api/state`, `/api/events` di `server.js` - nessun nuovo endpoint), aperto con:

`http://<host-server.js>:<porta>/?palmare=1`

Nasconde Setup, Monitor cucina e il pannello Delivery & Pick-up (pensati per uno schermo
desktop): resta tutto il resto della gestione tavoli (apertura, piatti, variazioni, conti
separati, unione tavoli, Invia/Pronta/Servita/Libera tavolo) con gli stessi permessi
dell'istanza principale - non e' una modalita' di sola lettura come quella remota.

## Note

- **Lezione hosting Aruba**: evitare la sintassi `INSERT ... ON DUPLICATE KEY UPDATE` con
  `MySql.Data.MySqlClient` su questo database — il driver .NET resta bloccato in lettura subito
  dopo che il comando e' gia' andato a buon fine lato server (probabilmente per il messaggio
  informativo extra che MySQL restituisce solo per questa sintassi), fino al timeout. Usare invece
  un `UPDATE` semplice seguito da un `INSERT` solo se non ha toccato righe (pattern gia' in uso in
  `HubRiseIntegration.UpsertOrder`). Anche le transazioni ADO.NET esplicite (`BeginTransaction`)
  su piu' comandi hanno mostrato blocchi simili: preferire connessioni con `Pooling=false` e
  comandi singoli in autocommit.
- Prima di collegare una sede reale in produzione, contattare `integration@hubrise.com` per la
  breve call di valutazione gratuita (circa 90 minuti).
