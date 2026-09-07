# Stato della revisione del progetto

Riferimento: `revisioneprogetto20260907.md`.

## Sicurezza API

- [x] Corpo delle richieste limitato a 2 MB.
- [x] API mutanti protette opzionalmente da `LOCAL_API_KEY`.
- [x] Accesso browser limitato allo stesso origin o a `ALLOWED_ORIGINS`.
- [x] CORS wildcard rimosso da Node e `MenuService`.
- [x] `UPDATE_KEY` e `DbAdminKey` confrontate a tempo costante.
- [x] File statici pubblicati tramite allowlist.
- [x] Stream statici con gestione dell'errore.
- [x] Errori non gestiti registrati in `crash.log` e servizio terminato per il riavvio da systemd.
- [x] Header sensibili del webhook Deliveroo oscurati nei log.
- [x] Chiavi di sincronizzazione Node, frontend e `RestaurantSync` trasferite tramite header.
- [ ] Chiavi dei flussi esterni che richiedono ancora query string: devono essere migrate solo insieme ai rispettivi client esterni.

## Dati e runtime

- [x] `ristorante-state.json` rimosso dall'indice Git e sostituito da `ristorante-state.example.json`.
- [x] Scritture JSON atomiche.
- [x] Poller Sigonella e sincronizzazione stato protetti da guardia in-flight.
- [x] Log operativi centralizzati e ruotati oltre 5 MB.
- [x] Pagamento disponibile tramite endpoint atomico con precondizione `stateRevision`.
- [x] Le route GET di lettura sono state estratte progressivamente in una tabella (`/api/state`, `/api/version`, `/api/table-locks`, `/api/table-lock`, `/api/fiscal-receipts`, `/api/fiscal-receipts/sync-status`).
- [ ] Il refactoring completo del server monolitico in moduli e router tabellare è ancora da completare in una migrazione separata.

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
- [ ] Rimozione dei duplicati storici e riorganizzazione della cartella `outputs` da fare con una successiva pulizia controllata.
