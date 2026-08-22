# Stato del progetto — Gestione comande Thai Princess (Catania)

Aggiornato al 2026-07-30. Scritto per poter riprendere il lavoro anche in una sessione nuova,
senza lo storico della conversazione.

## Cos'è

App di gestione sala/cucina/comande per il ristorante Thai Princess, più integrazione HubRise
(ordini delivery/pickup) e un'istanza esterna sincronizzata via DB remoto. Un'unica pagina HTML
serve sia l'uso in sala (desktop) sia l'uso da palmare/telefono, sia un'eventuale istanza fuori
LAN — tutto nello stesso file, con branching a runtime.

## File principali

- **`outputs/gestione-comande-ristorante.html`** — l'intera app frontend (HTML+CSS+JS in un unico
  file). Di gran lunga il file più grande e più modificato.
- **`server.js`** — backend Node locale, gira sul PC del ristorante. Autorità unica sullo stato
  condiviso (`sharedState`, persistito in `ristorante-state.json`), serve l'HTML, espone
  `/api/state` (GET/POST), `/api/events` (SSE), `/api/log-freed`, polling HubRise, push/poll verso
  `RestaurantSync.ashx`.
- **`RestaurantSync.ashx`** + **`RestaurantSync.sql`** — ponte per l'istanza esterna, ospitato su
  `https://thaiprincess.it`. Vedi sezione dedicata sotto.
- **`MenuService.asmx`** — legge il menu da MySQL (`v2_categories`/`v2_products`) e lo restituisce
  come JSON; **il nome categoria restituito è `name_en`, non `name_it`** (fonte di bug ricorrenti,
  vedi "Trappole note").
- **`HubRiseIntegration.README.md`** — setup/chiavi per l'integrazione HubRise (non duplicato qui).
- **`DbAdmin.ashx`** — endpoint generico per eseguire SQL sul DB remoto da riga di comando/script
  (header `X-Db-Admin-Key`, body `{sql, params?}`, **una sola istruzione per chiamata**).
- **`DeliverooBridge.exe`** (in `DeliverooBridge/publish-framework/`) — unico modo per pubblicare
  i file su thaiprincess.it via FTP: `./DeliverooBridge.exe upload "<locale>=<remoto>"`.

## Come si distribuisce una modifica

1. Editare il file locale.
2. Sintassi JS: `node -e "new Function(require('fs').readFileSync('outputs/gestione-comande-ristorante.html','utf8').match(/<script>([\s\S]*?)<\/script>/)[1])"` (o lo script più completo usato in sessione, che estrae tutti i blocchi `<script>`).
3. `./DeliverooBridge.exe upload "<path locale>=<path remoto>"` dalla cartella
   `DeliverooBridge/publish-framework`.
4. Se si tocca `server.js`: è un processo Node **già in esecuzione sul PC del ristorante**
   (avviato con `node server.js`, non da questa sessione) — le modifiche al file non hanno effetto
   finché non viene riavviato. **Non riavviarlo/spegnerlo di propria iniziativa**: è un sistema
   live, chiedere sempre prima (rischio di interrompere il servizio, e le variabili d'ambiente
   HubRise/RestaurantSync potrebbero essere impostate solo nella sessione di terminale del gestore,
   non in modo persistente).

## Modalità della stessa pagina HTML

- **Desktop/sala** (default): piantina tavoli, monitor cucina, pannello Delivery&Pickup, Setup.
- **`PALMARE_MODE`** (auto-detect UA/touch, o override `?palmare=1`/`?palmare=0`): niente
  Setup/Monitor/Delivery, elenco tavoli invece di piantina, un burger menu che raccoglie
  aggregazione/conti separati/sequenze/comandi, vista Piatti/Comanda alternabile (mai scroll
  continuo), feedback visivo/sonoro/vibrazione al tocco, tasti sequenza "seq: 1 2 3" che scelgono
  esplicitamente dove va il prossimo piatto aggiunto (`order.selectedCourse`, **ora rispettato
  anche su desktop**, non solo palmare — vedi fix sotto).
- **`REMOTE_MODE`** (`?remote=1&key=...`): istanza fuori LAN. Legge/scrive tramite
  `RestaurantSync.ashx` invece di `/api/state` locale. Può **solo** agire sui Pick-up manuali
  (`source==="manual"`): crearne uno, mandarlo in cucina, cambiare stato piatto, nota. Tavoli e
  ordini HubRise restano di sola lettura da remoto.

## Sistema di sincronizzazione esterna (RestaurantSync)

Architettura: il locale (`server.js`) resta l'unica fonte autorevole. Push periodico (~5s)
dell'istantanea completa; comandi dall'esterno messi in coda e applicati dal locale al giro
successivo (mai comando diretto sullo stato).

Tabelle (DB `Sql467031_5`, MySQL su Aruba — **mai `ON DUPLICATE KEY UPDATE`**, usare sempre
"UPDATE poi INSERT solo se 0 righe", lezione già nota da HubRise):

- **`restaurant_command_queue`** — coda comandi dall'esterno verso il locale (`client_command_id`
  univoco per idempotenza, `applied_at_utc` per conferma).
- **`restaurant_freed_log`** — log **permanente, senza limiti di tempo**, di ogni tavolo/pickup
  "liberato" (bottone "Libera tavolo"). Solo scrittura da `RestaurantSync.ashx` (`mode=log_freed`);
  nessun endpoint di lettura dedicato (si consulta via `DbAdmin.ashx` diretto).
- **`restaurant_turno_types`** — tipi di turno (es. "Servizio" 18→3). **Mai fare UPDATE su una riga
  esistente quando cambiano gli orari**: si inserisce una nuova riga e si marca la vecchia
  `is_active=0`, così lo storico resta legato agli orari realmente in vigore quando è stato creato.
- **`restaurant_state_snapshot`** — **non più una riga fissa sovrascritta**: una riga per ogni
  turno effettivo (`turno_type_id` + `turno_start`), con `state_payload` (ultima istantanea nota
  per quel turno) e `freed_log` (array JSON dei liberati **durante quel turno**, si azzera quando
  il turno cambia). La riga "corrente" è sempre quella con `id` più alto.

`server.js` calcola l'ora locale (```localNowString()```, formato `yyyy-MM-ddTHH:mm:ss`) e la manda
ad ogni `push_state`/`log_freed` come query string `now=...`: è l'unica macchina di cui fidarsi per
l'orario giusto (l'hosting remoto potrebbe essere su un altro fuso). `RestaurantSync.ashx` usa
`ResolveCurrentTurno()` per decidere a quale turno appartiene quell'ora (gestisce le finestre che
attraversano la mezzanotte, es. 18→3) e `GetLatestSnapshotRow()`/confronto per capire se aggiornare
la riga corrente o aprirne una nuova.

`mode=state` (GET) restituisce `{"state": {...}, "turno_start": "...", "turno_label": "...",
"freed_log": [...]}` — stessa forma di `/api/state` locale più i tre campi extra (il front-end
esistente li ignora finché non li usa esplicitamente).

## Navigazione via hash (`#order-<id>`)

Problema: sul palmare un refresh involontario (pull-to-refresh) o il tasto back del telefono
facevano perdere il tavolo aperto / uscivano dalla pagina. Soluzione: `openOrderModal()` imposta
`location.hash = "order-" + id"` (spinge una history entry); `closeOrderModal()` pulisce l'hash con
`history.replaceState` (mai push, per non intasare la history su ogni chiusura); una funzione
`openOrderFromHash()` (chiamata sia al load sia su `hashchange`) riapre da sola l'ordine giusto
dopo un refresh, o chiude il modale quando l'hash torna vuoto (il back del telefono "sfoglia via"
la voce di history invece di uscire dalla pagina). Vale sia in palmare che su desktop, sia per
tavoli (id numerico) che per Pick-up/HubRise (id stringa).

## Setup → Monitor: bug trovati e risolti in questa sessione

Sintomo riportato: "tutto fuori sequenza" nonostante categorie assegnate correttamente al monitor
giusto. Causa a catena (tre bug distinti, tutti corretti):

1. `saveMonitorConfig()` leggeva un input `.monitor-name` che nel markup attuale non esiste più (il
   nome del monitor è testo semplice, non più rinominabile da lì): la funzione andava in errore
   **prima** di scrivere `monitor.turns`, quindi spuntare/togliere "Usa sequenze" sembrava
   salvarsi ma non veniva mai davvero persistito. **Risolto.**
2. Il salvataggio di "Categorie" (`monitorCategoriesForm` submit) scriveva
   `categoryTurns[categoria] = <flag del monitor aperto>` per **ogni** categoria della lista, non
   solo per quelle assegnate a quel monitor — bastava salvare le Categorie di "Bar" per corrompere
   silenziosamente il flag di tutte le categorie di cucina. **Risolto** (ora tocca `categoryTurns`
   solo per le categorie effettivamente spuntate/assegnate).
3. Al caricamento (`loadState()`), un blocco ricostruiva `monitor.turns` leggendo `categoryTurns`
   invece di fidarsi del valore già salvato sul monitor — quasi certamente il meccanismo che ha
   silenziosamente ribaltato "Usa sequenze" di Cucina dopo che era stato corretto solo Bar.
   **Rimosso**: `monitor.turns` è ora l'unica fonte di verità.
4. Categorie "fantasma" (`Cucina`, `Bevande`, `Pizzeria`, `Pasticceria` come CHIAVI di
   `categoryMonitors`/`categoryTurns`) — residuo del template originale, mai state categorie reali
   di questo menu (sono nomi di monitor, non di categorie). Rimosse da default, migrazione, e dati
   live via pruning (`loadState()` ora elimina ogni chiave non presente in
   `state.settings.categories`).
5. CSS: `.checkbox-label` non aveva nessuna regola generale (solo scoped a `.monitor-setup`), causa
   di un disallineamento verticale checkbox/testo nel modale "Categorie". Aggiunta una regola
   generale `display:flex; align-items:center; gap:6px`.

**Stato attuale confermato** (dopo i fix, sul DB/stato live): monitor "Bar" → `turns:false`
(corretto, drink/vini fuori sequenza), monitor "Cucina" → `turns:true` (corretto, piatti in
sequenza), `categoryMonitors`/`categoryTurns` contengono solo le 15 categorie reali del menu
(Starters, Noodles, Special Bangkok, Curry, Soups, Thai Style 100%, Seafood, Desserts, Extra Rice,
Drinks, White Wines, Red Wines, Rosé Wines, Sparkling Wines, Spirits).

**Nota importante**: `MenuService.asmx` restituisce `name_en` come nome categoria (non `name_it`).
Per questo ristorante i nomi reali sono quelli sopra in inglese — "Bevande"/"Vini Bianchi" **non**
esistono come chiavi valide, solo come testo del CSV originale/`name_it` nel DB.

## Comanda: bar (fuori sequenza) vs sequenze

Ordine finale nella comanda (dopo un paio di correzioni avanti e indietro in sessione): **coperto →
bar (fuori sequenza) → sequenza 1 → sequenza 2 → ...**. Gli articoli "fuori sequenza" (categoria
mappata su un monitor con `turns:false`) non hanno il bottone "Apri variazioni" (non hanno
ingredienti configurabili, solo nome/quantità).

Il monitor/categoria di un articolo determina se usa le sequenze
(`lineUsesTurns()`/`monitorForLine()` in `gestione-comande-ristorante.html`) — vedi sopra per i bug
di allineamento risolti.

## Import vini/bar (dati reali, non test)

Importate da un export CSV del punto vendita: 5 nuove categorie DB (`v2_categories` id 11-15:
Vini Bianchi/White Wines, Vini Rossi/Red Wines, Vini Rosati/Rosé Wines, Spumanti/Sparkling Wines,
Liquori/Spirits, tutte `is_visible=0`, `sort_order` 92-96) e 140 prodotti (`v2_products`, tutti
`is_active=1`, `is_delivery=0`). File di riferimento: `ImportVinoBar.sql` (copia documentativa
dell'SQL usato). Nota risolta: encoding "Rosé" — deve avere l'accento acuto (é), non grave (è); va
sempre passato UTF-8-encoded a mano se si scrive da PowerShell 5.1 verso `DbAdmin.ashx`
(`ConvertTo-Json` + `Invoke-RestMethod` corrompe gli accentati altrimenti — usare
`[System.Text.Encoding]::UTF8.GetBytes($json)` come body raw).

## Pulizia "sistema pulito" (fatta il 2026-07-30)

Su richiesta esplicita, ripulito tutto lo stato di test:

- **Locale** (`ristorante-state.json`): 12 tavoli azzerati (nessun occupato, comande/sottoconti/
  sequenze puliti, rimosso `formerTableId` residuo), rimossi i 5 ordini Pick-up di prova e lo
  storico. Menu/impostazioni/variazioni/layout sala **non toccati**.
- **DB remoto**: svuotate `restaurant_state_snapshot` e `restaurant_command_queue`;
  `restaurant_freed_log` era già vuota. `restaurant_turno_types` **non toccata** (configurazione
  reale, non dato di test).
- **Log locali**: `hubrise-feed.log`, `print-simulation.log`, `restaurant-sync.log` svuotati.

## Trappole note (da ricordare per non ripetere gli stessi bug)

- **CSS `[hidden]`**: regole autore con specificità pari o inferiore (es. `.stack{display:grid}`)
  battono SEMPRE lo user-agent default `[hidden]{display:none}`, indipendentemente dalla
  specificità — serve un `selector[hidden] { display:none; }` esplicito ogni volta che una classe
  con `display` esplicito viene applicata a un elemento anche gestito via attributo `hidden`.
- **Nodo staccato durante il bubbling**: se un click handler fa un re-render sincrono che ricrea il
  proprio antenato, `event.target.closest(...)` nella fase di bubbling fallisce (parentElement
  diventato null) — un listener esterno "click fuori, richiudi" può scattare per errore. Fix:
  `event.stopPropagation()` sul bottone interno.
- **`crypto.randomUUID()`** richiede contesto sicuro (HTTPS o localhost) — fallisce silenziosamente
  su IP LAN in HTTP semplice; se chiamato dentro un `const` top-level valutato al parse, blocca
  l'intero script. Polyfill Math.random()-based già in uso.
- **PowerShell 5.1 + `ConvertTo-Json` + `Invoke-RestMethod`** corrompe caratteri accentati nel body
  JSON — serve `[System.Text.Encoding]::UTF8.GetBytes($json)` passato come `-Body` raw.
- **`MenuService.asmx` restituisce `name_en`**, non `name_it`, come nome categoria — qualunque
  mappatura categoria→monitor/turno va scritta con i nomi inglesi reali, non quelli del CSV
  italiano originale.
- **Firewall Windows** blocca di default connessioni LAN in ingresso a `server.js` (solo
  localhost/127.0.0.1 esente) — va aperta una regola (`New-NetFirewallRule`) sul PC del ristorante,
  non qualcosa che si possa fare da questa sessione.
- **`/api/state` POST fa un merge speciale su `deliveryOrders`** (unione client+server per id, mai
  sostituzione secca): per svuotarli davvero da fuori serve fermare `server.js`, editare
  `ristorante-state.json` a mano, poi far ripartire il processo — POSTare un array vuoto NON li
  cancella (vengono ri-uniti come "solo server").

## Possibili prossimi passi (non richiesti esplicitamente, solo annotati)

- Nessun endpoint di lettura per `restaurant_freed_log` (solo scrittura) — se servisse consultarlo
  da remoto andrebbe aggiunto un `mode` dedicato a `RestaurantSync.ashx`.
- Integrazione Nexi SmartPOS: esplorata solo a livello di ricerca (non implementata). Percorsi
  reali trovati: Terminal Applications (app Android nativa sul terminale), Payment Bridge API
  (REST, remoto), ECR-LAN/PosConnector (locale, LAN, il più vicino alla nostra architettura). Serve
  accordo/account developer con Nexi (contattabile tramite il referente commerciale esistente, dato
  che il ristorante ha già un terminale attivo). Nessun collegamento col "piccolo gestionale"
  interno allo SmartPOS (Comande/kitchen monitor Nexi): è un protocollo proprietario non
  documentato pubblicamente, solo per i loro stessi dispositivi via Wi-Fi locale.
- Il collegamento cassa-POS obbligatorio 2026 (Protocollo 17/ECR17 in generale) è **amministrativo**
  (registrazione una tantum su portale "Fatture e Corrispettivi" Agenzia Entrate), non tecnico:
  nulla da costruire in questo repo per la sola conformità.
