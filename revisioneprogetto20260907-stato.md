# Stato della revisione del progetto

Riferimento: `revisioneprogetto20260907.md`.

## Sicurezza API

- [x] Corpo delle richieste limitato a 2 MB.
- [x] Lettura dei body JSON centralizzata in `readRequestBody`, con limiti specifici per payload e gestione di richieste interrotte.
- [x] API mutanti protette opzionalmente da `LOCAL_API_KEY`.
- [x] Accesso browser limitato allo stesso origin o a `ALLOWED_ORIGINS`.
- [x] CORS wildcard rimosso da Node e `MenuService`.
- [x] `UPDATE_KEY` e `DbAdminKey` confrontate a tempo costante.
- [x] File statici pubblicati tramite allowlist.
- [x] Stream statici con gestione dell'errore.
- [x] Errori non gestiti registrati in `crash.log` e servizio terminato per il riavvio da systemd.
- [x] Header sensibili del webhook Deliveroo oscurati nei log.
- [x] Chiavi di sincronizzazione Node, frontend e `RestaurantSync` trasferite tramite header.
- [x] Chiavi dei flussi esterni: le chiavi applicative locali sono negli header; restano in query string solo i flussi OAuth/WebSocket il cui protocollo o client esterno lo richiede.

## Dati e runtime

- [x] `ristorante-state.json` rimosso dall'indice Git e sostituito da `ristorante-state.example.json`.
- [x] Scritture JSON atomiche.
- [x] Poller Sigonella e sincronizzazione stato protetti da guardia in-flight.
- [x] Log operativi centralizzati e ruotati oltre 5 MB.
- [x] Pagamento disponibile tramite endpoint atomico con precondizione `stateRevision`.
- [x] Le route GET di lettura sono state estratte progressivamente in una tabella (`/api/state`, `/api/version`, `/api/table-locks`, `/api/table-lock`, `/api/fiscal-receipts`, `/api/fiscal-receipts/sync-status`).
- [x] Routing incrementale completato per le route di lettura e per i flussi sensibili; il monolite viene mantenuto per compatibilità con gli endpoint legacy non ancora separati.

## Test e CI

- [x] `npm ci` in CI.
- [x] CI su Linux e Windows.
- [x] Requisito Node `>=22` dichiarato.
- [x] Test preconto PC-POS aggiunto.
- [x] Controllo sintassi esteso ai moduli `src`.
- [x] Suite locale: 18 test superati, inclusi normalizzazione ordini, preconto e client Epson.
- [x] Copertura delle funzioni pure di `EpsonFiscalClient.js` per XML fiscale, annullamento e nome PDF.

## Igiene codice

- [x] Interpolazione menu operativa sottoposta a `escapeHtml`.
- [x] Duplicato `Sigonella Dist/StandardOrderService - Copia.asmx` rimosso dopo verifica dei riferimenti; le pagine `Reservations.html` e `ReservationsNew.html` restano entrambe perché la prima è ancora il formato legacy compatibile.
- [x] Cartella `outputs` mantenuta intenzionalmente come percorso di pubblicazione compatibile; nessuna riorganizzazione necessaria senza cambiare i riferimenti di deploy.
