# Memoria e sincronizzazione

## Livelli di memoria

L'applicazione separa tre livelli:

1. **Configurazione piattaforma**: dati comuni al ristorante e ai dispositivi.
2. **Memoria locale browser**: preferenze e layout del singolo dispositivo.
3. **Stato del turno**: dati operativi condivisi tra le istanze.

### Configurazione piattaforma

Comprende sala, definizione e layout dei tavoli, impostazioni, stampanti, POS, monitor, assegnazione delle categorie, sequenze e variazioni. Il menu è un catalogo separato, caricato tramite `/api/menu` e mantenuto in `menu-cache.json`.

Nel browser è memorizzata in `ristorante-platform-config-v1`. Viene caricata all'apertura o al refresh con:

```text
GET /api/platform-config
```

Le modifiche usano una chiamata separata:

```text
POST /api/platform-config
```

Sul Node locale viene conservata in `restaurant-config.json`.

### Memoria locale browser

Comprende tavolo selezionato, categoria visualizzata, dimensioni del modal, posizioni e dimensioni dei tavoli, layout prima pagina, layout/colori dei monitor e preferenze mobile/desktop.

Le chiavi principali sono:

```text
ristorante-browser-ui-v1
restaurant.table-layout.v1
restaurant-main-layout-v1
vorrei-kitchen-layout
```

Questi dati non vengono inviati al server durante il polling.

### Stato del turno

Comprende solo i tavoli occupati e le relative comande, ordini delivery/pick-up, prenotazioni attive, pagamenti, stati operativi e revisioni necessarie alla concorrenza. La definizione dei tavoli liberi, comprese posizione e dimensioni, appartiene alla configurazione piattaforma. Non contiene una copia separata dello storico monitor.

La cronologia delle comande segue il ciclo di vita del tavolo:

1. Fino al pagamento le comande restano nello stato locale; il monitor le mostra o nasconde usando il flag `kitchenClosed` sulla comanda.
2. Anche dopo che una comanda e' stata nascosta come completata, resta disponibile nello stato locale fino alla chiusura del tavolo.
3. Quando l'operatore libera il tavolo, il client registra prima la comanda in `restaurant_freed_log` tramite `/api/log-freed`.
4. Solo dopo una risposta HTTP positiva il client rimuove la comanda dallo stato operativo e sostituisce il tavolo con uno nuovo. Da quel momento la comanda risiede solo sul server remoto.
5. Se la registrazione remota fallisce, il tavolo e la comanda restano locali e l'operatore riceve un errore.

Nel browser usa `ristorante-comande-v1`; sul Node locale usa `ristorante-state.json`.

Gli scontrini sono separati dallo state operativo:

```text
fiscal-receipts.json
fiscal-receipt-sync.json
fiscal-receipts-pdf/
```

## Client e Node locale

Il polling operativo usa esclusivamente:

```text
GET  /api/state
POST /api/state
```

Questi payload contengono solo lo stato del turno. `platformConfig`, menu, layout e preferenze browser non sono inclusi.

La configurazione usa gli endpoint indipendenti `/api/platform-config`.

## Realtime

Il Node locale espone gli eventi con `GET /api/events`.

- `state.updated`, `order.created`, `order.updated`, `order.deleted`: rilettura di `/api/state`.
- `reservation.updated`: rilettura dello stato e aggiornamento delle prenotazioni.
- `platform-config.updated`: rilettura separata di `/api/platform-config`.

Il realtime è quindi un trigger: non trasporta la configurazione dentro lo stato e non sostituisce le chiamate di lettura.

## Node locale e server remoto

Con `RESTAURANT_SYNC_KEY` configurata, Node pubblica periodicamente lo snapshot operativo verso:

```text
RestaurantSync.ashx?mode=push_state
```

La pubblicazione è basata sulla revisione dello stato. Menu e layout locali non fanno parte dello snapshot.

I comandi remoti vengono letti e confermati tramite:

```text
RestaurantSync.ashx?mode=pending_commands
RestaurantSync.ashx?mode=ack_commands
```

Il client remoto legge lo stato con `RestaurantSync.ashx?mode=state` e usa il realtime remoto come trigger per una nuova lettura.

Per aggiornare la configurazione anche sul client remoto, il server remoto deve esporre separatamente:

```text
RestaurantSync.ashx?mode=platform-config
```

Questo endpoint non deve incorporare la configurazione nello snapshot dello stato.

## Reset del turno

Il reset ricrea solo la parte operativa: elimina comande, prenotazioni e pagamenti del turno, mantenendo configurazione, menu e memoria locale del browser. Le installazioni precedenti con JSON monolitico vengono migrate automaticamente all'apertura della pagina.
