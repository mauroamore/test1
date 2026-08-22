# Riassunto integrazione HubRise

## Cosa è stato fatto

Integrazione da zero (nessun riuso del codice Deliveroo esistente) per ricevere ordini da HubRise
— che aggrega Deliveroo, JustEat, UberEats ecc. dietro un'unica API — bypassando il bisogno di
approvazione diretta da parte di ciascuna piattaforma di delivery, che per Deliveroo non è ancora
arrivata e per JustEat non arriverà.

**Scope di questo giro**: solo ricezione ordini (connessione OAuth, webhook, salvataggio DB,
comparsa sulla schermata comande locale). Sync catalogo/menu e aggiornamento automatico di stato
ordine verso HubRise sono rimandati a un giro successivo.

## Architettura

- **Hosting remoto** (`thaiprincess.it`, IIS/ASP.NET classico + MySQL): riceve il webhook HubRise,
  salva gli ordini nel database, espone un feed e un monitor di sola lettura.
- **Node locale** (`server.js`, gira su una macchina del ristorante): interroga periodicamente il
  feed remoto, mostra gli ordini delivery nella schermata comande via SSE, serve sia la postazione
  principale che i palmari sulla stessa rete locale.
- **Postazione di controllo esterna**: pagina statica (`HubRiseMonitor.html`) che legge dati
  direttamente dall'hosting remoto, quindi funziona da qualunque rete, non solo da quella del
  ristorante.

## File creati

| File | Ruolo |
|---|---|
| `HubRiseConnection.sql`, `HubRiseWebhook.sql`, `HubRiseOrders.sql`, `HubRiseProcessLog.sql` | Schema DB (`hubrise_*`) |
| `App_Code/HubRiseIntegration.cs` | Helper condiviso: DB, chiamate API HubRise, upsert ordini |
| `HubRiseConnect.ashx` | Connessione OAuth one-time + registrazione webhook (`register_webhook=1`) |
| `HubRiseWebhook.ashx` | Ricezione ordini: verifica HMAC, log, salvataggio asincrono con retry |
| `HubRiseOrdersFeed.ashx` | Feed consumato dal Node locale (marca gli ordini come "fetched") |
| `HubRiseService.asmx` + `HubRiseMonitor.html` | Monitor esterno di sola lettura, protetto da chiave |
| `DbAdmin.ashx` + `DbAdminLog.sql` | Endpoint di amministrazione DB generico (lettura/scrittura), con log di audit |
| `HubRiseIntegration.README.md` | Guida completa di setup e configurazione |

File modificati (estensioni mirate, Deliveroo non toccato):
- `server.js` — polling del feed, pannello "Ordini Delivery", indicatore offline, opzione `HOST` per il bind
- `outputs/gestione-comande-ristorante.html` — nuovo pannello "Ordini Delivery"
- `DeliverooBridge/Program.cs` — comando `upload` esteso per caricare file anche in sottocartelle (es. `App_Code/`)

## Problemi incontrati e risolti

Il grosso del lavoro, dopo l'impianto iniziale, è stato diagnosticare perché gli ordini arrivavano
ma non venivano salvati. Cause trovate, in ordine:

1. **Struttura webhook diversa dal previsto**: HubRise incapsula l'ordine dentro `new_state`
   (envelope `{resource_type, event_type, order_id, new_state: {...}}`), non come creduto
   inizialmente — corretto in `HubRiseIntegration.ExtractOrderNode`.
2. **Tabelle mancanti**: `hubrise_process_log` non era stata creata; senza di essa gli errori reali
   restavano invisibili (il log stesso falliva silenziosamente).
3. **`INSERT ... ON DUPLICATE KEY UPDATE` blocca il driver .NET su questo hosting** (Aruba): il
   comando va a buon fine lato server, ma `MySql.Data.MySqlClient` resta bloccato in lettura subito
   dopo, fino al timeout — probabilmente per come interpreta il messaggio informativo extra che
   MySQL restituisce solo per questa sintassi. Sostituito con "UPDATE, e se non tocca righe allora
   INSERT" in `HubRiseIntegration.UpsertOrder`.
4. **Transazioni ADO.NET esplicite** (`MySqlTransaction`) mostravano lo stesso tipo di blocco;
   rimosse a favore di comandi singoli in autocommit.
5. **Timeout troppo corti** (5s) in più punti, alzati a 25s per dare margine.
6. **`ThreadPool.QueueUserWorkItem`** per il lavoro in background sostituito con
   `HostingEnvironment.QueueBackgroundWorkItem`, il meccanismo corretto in ASP.NET classico per non
   rischiare che IIS interrompa un lavoro avviato dopo la chiusura della risposta HTTP.
7. **Porta locale bloccata**: Windows aveva riservato dinamicamente l'intervallo 8767–8866
   (verosimilmente Hyper-V/WSL2), impedendo a `server.js` di aprire la porta 8787. Risolto
   spostandosi su una porta fuori da quell'intervallo (variabile `PORT`).

Tutte queste lezioni sono documentate anche in `HubRiseIntegration.README.md`.

## Stato attuale

Funzionante end-to-end: ordine di test iniettato da HubRise → webhook ricevuto e verificato →
salvato nel database → recuperato dal Node locale → visibile nel pannello "Ordini Delivery" della
schermata comande.

Verificati anche i due controlli facoltativi: monitor esterno raggiungibile da una rete diversa da
quella del ristorante, e comportamento corretto in assenza di connettività (gestione tavoli sempre
reattiva, pannello delivery che segnala "non disponibile" e si riprende da solo al ritorno della
rete, senza riavviare `server.js`).

## Aggiunta successiva: sync catalogo/menu

- `HubRiseCatalogSync.ashx` — sync manuale (mai automatico) verso `PUT /catalogs/:id`, sorgente
  `v2_categories`/`v2_products` (stessa di `MenuService.asmx`), filtro `is_active=1 AND
  is_delivery=1`. Ref code deterministici (`C{id}`/`P{id}`), nessuna tabella di mapping necessaria.
  Una sola SKU per prodotto (niente varianti/opzioni a pagamento: gli "ingredienti" locali sono
  solo informativi). Niente immagini in questo giro.
- Richiede lo scope OAuth `catalog.write`, aggiunto ora a `HubRiseScope` — la connessione
  stabilita in precedenza (senza quello scope) va rifatta prima di poter caricare il catalogo.
- **Verificato**: caricamento riuscito, 10 categorie e ~80 prodotti live su HubRise (verificabile
  con l'app Catalog Manager).
- **Nota emersa durante il debug**: il vecchio client OAuth aveva smesso di essere riconosciuto da
  HubRise ("No client found with this client_id and client_secret") pur risultando identico nel
  portale — risolto creando un client OAuth nuovo da zero in Settings > Developer e rifacendo la
  connessione. Se ricapita, non perdere tempo a confrontare le stringhe: creare direttamente un
  nuovo client.

## Aggiunta successiva: invio ordini delivery in cucina

Gli ordini HubRise possono ora essere trasformati in ordini interni ed entrare nello stesso flusso
cucina usato per i tavoli, invece di restare solo un elenco di sola lettura:

- **`HubRiseOrdersFeed.ashx`** risolve la categoria di ogni articolo risalendo dal `hubrise_ref`
  (es. `P27`, lo stesso ref assegnato da `HubRiseCatalogSync.ashx`) al prodotto locale e alla sua
  categoria in `v2_products`/`v2_categories` — cosi' l'articolo viene instradato sul monitor cucina
  giusto (bar, cucina, ecc.) esattamente come un articolo da tavolo. Se il ref non corrisponde a
  nessun prodotto reale (es. ordini di test con cataloghi finti), l'articolo finisce sul monitor di
  default ("Cucina").
- **`server.js`** costruisce per ogni ordine delivery un array `lines[]` nello stesso formato usato
  dai tavoli (`qty`, `sentQty`, `category`, `course`, `kitchenStatus`, ecc.).
- **Pannello "Ordini Delivery"**: ogni ordine ha un bottone **"Manda in cucina"** — segna tutte le
  righe come inviate (`sentQty = qty`), esattamente come il bottone di invio di un tavolo.
- **Monitor cucina**: gli ordini delivery inviati compaiono tra i ticket attivi con etichetta
  "Delivery · nome cliente" invece di "Tavolo N"; ogni piatto si clicca per far scorrere lo stato
  (Da preparare → In preparazione → Completo) come un tavolo normale; quando tutti i piatti sono
  completi appare il bottone **"Consegnato"** (equivalente di "Chiudi comanda") per rimuoverlo dal
  monitor attivo.
- Nessuna modifica al modello dei tavoli fisici: gli ordini delivery restano in
  `state.deliveryOrders[]`, solo il monitor cucina ora legge anche da li'.

**Tre bug reali scoperti testando con prodotti/ref veri (non c'entrava l'hosting Aruba stavolta)**:
1. `GetList` usava `value as List<object>`, ma `JavaScriptSerializer` rappresenta gli array JSON
   come `ArrayList`: il cast falliva silenziosamente e **nessun articolo/opzione ordine è mai stato
   salvato**, per nessun ordine, dall'inizio. Corretto convertendo esplicitamente via `IEnumerable`.
2. Il ref della SKU nel payload HubRise si chiama `sku_ref`, non `sku`/`ref` come cercavo — quindi
   il collegamento al catalogo (necessario per instradare l'articolo sul monitor giusto) era sempre
   vuoto. Corretto.
3. Prezzi/totale HubRise sono testo tipo `"12.34 EUR"`, non numeri puri: il parsing decimale
   falliva sempre silenziosamente. Corretto isolando la parte numerica e ricavando la valuta dal
   suffisso.

Tutti e tre confermati risolti con un ordine di prova reale (P1/P80): totale, valuta, articoli e
ref tutti corretti nel database.

**Quarto bug (diverso, di mia introduzione precedente)**: il merge di `deliveryOrders` nel POST
`/api/state` di `server.js` sostituiva sempre l'intero elenco con la versione precedente per non
perdere ordini appena arrivati dal polling — ma questo cancellava anche azioni legittime
dell'operatore (es. "Manda in cucina" spariva subito dopo il click). Corretto con un merge vero:
gli ordini gia' noti al browser vengono presi dalla sua versione, quelli arrivati nel frattempo
lato server vengono comunque preservati.

**Aggiunta**: colonna `collection_code` su `hubrise_order` (il codice che HubRise assegna per far
riconoscere l'ordine al rider in ritiro) — ora salvata e mostrata sulla card di ogni ordine
delivery insieme a numero ordine e orario di ricezione.

## Aggiunta successiva: ordini delivery apribili/modificabili come un tavolo

Cliccando una card nel pannello "Ordini Delivery" ora si apre lo stesso modale di modifica ordine
usato per i tavoli: si possono aggiungere piatti dal menu, scrivere note (es. richieste telefoniche
del cliente: "meno piccante", ecc.), cambiare quantita', applicare variazioni.

- `currentOrder()` ora usa `findOrderById(state.selectedTable)` invece di cercare solo fra i
  tavoli — riusa quindi tutta la logica esistente di aggiunta/modifica articoli senza duplicarla.
- Nascosti, solo per gli ordini delivery, gli elementi che non hanno senso fuori dal contesto
  "tavolo fisico": unione tavoli, split conto, richiesta coperti all'apertura.
- **"Servita e chiudi conto"**, per un ordine delivery, non tocca tavoli/storico: marca solo
  l'ordine come completato (stesso effetto di "Consegnato" dal monitor cucina) e lo fa sparire dal
  pannello.
- Corretti due punti che assumevano sempre un tavolo: `setStatus()` e "Annulla modifiche"
  (`discardChangesBtn`), ora generalizzati per funzionare anche sugli ordini delivery.
- Le sequenze (portate scaglionate nel tempo, tipo antipasto/primo/secondo) non hanno senso per un
  ordine delivery: un ordine delivery mostra sempre un solo box (mai una "sequenza 2"), con
  l'etichetta sostituita da piattaforma + codice ritiro (es. "Glovo 8455") invece di "Sequenza 1".
  Aggiunta anche colonna `channel` su `hubrise_order` (piattaforma di origine: Deliveroo, JustEat,
  Glovo, UberEats...) per costruire quell'etichetta. Vale solo per gli ordini arrivati dopo questa
  modifica: quelli piu' vecchi mostrano "Delivery {id}" come segnaposto.

## Aggiunta successiva: pannello "Delivery & Pick-up" e aggiornamento di stato ordine

- Il pannello si chiama ora "Delivery & Pick-up", con un bottone **+** per inserire manualmente un
  ordine Pick-up (nome cliente + orario di ritiro, anche "Subito"): crea un ordine "virtuale" e
  apre subito il modale di modifica; annullando il dialogo nome/orario l'ordine virtuale sparisce
  del tutto, confermando invece resta nel pannello come gli ordini HubRise (stesso modale, stesse
  regole: niente coperti/split/sequenze). Gli ordini Pick-up manuali non hanno nulla da
  sincronizzare su HubRise (non esistono li').
- **Aggiornamento di stato verso HubRise** (solo per ordini realmente originati da HubRise):
  - Webhook ricevuto e ref articoli tutti validi → conferma automatica `received`.
  - "Manda in cucina" → `accepted` poi `in_preparation`.
  - "Consegnato" → `awaiting_collection`.
  - Nuovo endpoint remoto `HubRiseOrderStatus.ashx` + relay locale in `server.js`
    (`/api/hubrise/status`, chiave `HUBRISE_STATUS_KEY`) cosi' il browser non tocca mai la chiave
    HubRise direttamente.

## Aggiunta successiva: tempo di preparazione (confirmed_time)

Quando si manda in cucina un ordine HubRise, un prompt chiede tra quanti minuti sara' pronto: se
indicato, viene mandato a HubRise come `confirmed_time` insieme al passaggio a `in_preparation`,
sovrascrivendo l'`expected_time` proposto dalla piattaforma (utile se serve piu' tempo del previsto).
Lasciare vuoto il prompt non blocca l'invio in cucina, semplicemente non tocca l'orario.

Nota su un secondo tema sollevato (piattaforme che aspettano di trovare un rider prima di dirci di
preparare): dalla documentazione HubRise risulta che e' la piattaforma stessa (es. Uber Eats) a
ritardare l'invio dell'ordine fino al momento giusto, in base a un tempo di preparazione
configurato sulla connessione HubRise-piattaforma — non richiede nessuna modifica lato nostro,
l'ordine arriva gia' solo quando e' davvero il momento di iniziare.

## Prossimi passi (fuori scope in questo giro)

- Caricamento immagini prodotto nel catalogo HubRise.
- Prima di collegare una sede reale in produzione: contattare `integration@hubrise.com` per la
  breve call di valutazione gratuita (~90 minuti).
