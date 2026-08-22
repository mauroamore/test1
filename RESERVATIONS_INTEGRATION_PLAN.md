# Piano integrazione Reservations

## Obiettivo

Integrare nel gestionale comande le funzioni utili della pagina `Reservations.html`, mantenendo semplice il lavoro della sala.

La gestione dell'occupazione resta quella attuale. Le prenotazioni servono a:

- mostrare accanto ai tavoli le prenotazioni associate;
- marcare una prenotazione come `Seduto`;
- collegare automaticamente i tavoli gia' assegnati alla prenotazione;
- inserire automaticamente i coperti della prenotazione;
- alimentare gli stati operativi del tavolo.

## Stati tavolo

Gli stati operativi da usare nel gestionale sono:

```text
libero
prenotato
seduto
in_preparazione
completato
chiuso
```

`status` resta lo stato della comanda/cucina esistente.

`tableStatus` rappresenta invece lo stato operativo del tavolo lato sala.

## Regole operative

### Prenotato

Un tavolo risulta `prenotato` quando esiste almeno una prenotazione attiva associata a quel tavolo e il tavolo non e' ancora occupato da una comanda.

Lo stato puo' essere derivato dalle prenotazioni, senza obbligare la sala ad aggiornarlo a mano.

### Seduto

Il cameriere marca la prenotazione come `Seduto`.

Da quel momento il gestionale deve fare tutto automaticamente:

- leggere i tavoli associati alla prenotazione;
- scegliere come tavolo principale il primo della lista;
- collegare gli altri tavoli al principale;
- inserire i coperti della prenotazione;
- impostare il tavolo principale come occupato;
- impostare `tableStatus = "seduto"`;
- salvare lo stato.

Non deve comparire nessun modal e non devono essere richieste conferme.

Eventuali variazioni successive, come coperti diversi o tavoli cambiati, saranno gestite dal palmare o dai flussi gia' esistenti.

### In preparazione

Al primo invio in cucina:

```text
seduto -> in_preparazione
```

La transizione e' automatica.

### Completato

Quando tutte le righe/sequenze della comanda sono complete:

```text
in_preparazione -> completato
```

La transizione e' automatica.

### Chiuso / Libero

Quando il conto viene chiuso o il tavolo viene liberato:

```text
completato/chiuso -> libero
```

La chiusura deve pulire lo stato operativo del tavolo e sganciare l'eventuale prenotazione seduta.

## Modello dati proposto

### Tavolo

Campi aggiuntivi su ogni tavolo:

```js
{
  tableStatus: "libero",
  seatedReservationId: null
}
```

### Prenotazione

Formato interno normalizzato:

```js
{
  id: "reservation-1",
  name: "Rossi",
  time: "2026-08-08T20:30:00",
  covers: 4,
  tableIds: [3, 4],
  status: "prenotato"
}
```

Stati prenotazione minimi:

```text
prenotato
seduto
completato
chiuso
noshow
```

Il formato deve accettare anche dati provenienti dalla vecchia `Reservations.html`, dove i tavoli possono essere contenuti in `notes` come JSON.

## Fasi di implementazione

### Fase 1 - Base dati e visualizzazione

Stato: avviata.

Attivita':

- aggiungere `state.reservations`;
- aggiungere `tableStatus` ai tavoli;
- normalizzare lo stato al caricamento;
- mostrare le prenotazioni nella piantina;
- aggiungere azione automatica `Seduto`;
- aggiornare gli stati su invio cucina, completamento e liberazione.

Verifiche:

```powershell
node --check server.js
node --check gestione-comande-ristorante.extracted.js
```

### Fase 2 - Alimentazione prenotazioni

Da decidere.

Opzioni:

- importare il formato di `Reservations.html`;
- aggiungere endpoint server locali per leggere/scrivere prenotazioni;
- creare un pannello minimale nel gestionale;
- collegarsi in futuro al database o servizio usato oggi da `Sigonella.aspx/GetReservations`.

Requisiti:

- non introdurre credenziali nel progetto;
- non usare `ristorante-state.json` come specifica;
- mantenere compatibilita' con prenotazioni associate a piu' tavoli.

### Fase 3 - Gestione UI prenotazioni

Interfaccia minima desiderata:

- elenco prenotazioni del giorno;
- ricerca per nome/ora;
- assegnazione tavoli;
- modifica coperti;
- cambio stato prenotazione;
- pulsante `Seduto`.

Il pulsante `Seduto` deve continuare a eseguire l'automazione senza modal.

### Fase 4 - Conflitti e sovrapposizioni

Riprendere da `Reservations.html` la logica di sovrapposizione entro circa 2 ore.

Comportamento:

- se una prenotazione usa un tavolo gia' assegnato nello stesso intervallo, segnalarlo;
- non bloccare necessariamente l'operatore;
- mostrare un avviso visivo chiaro nella lista prenotazioni o accanto al tavolo.

### Fase 5 - Palmare

Adattare la vista palmare:

- mostrare lo stato tavolo;
- indicare prenotazioni associate;
- permettere la correzione successiva di coperti e tavoli collegati;
- evitare nuove interazioni obbligatorie per la sala.

### Fase 6 - Integrazioni future

Predisposizioni non visibili all'utente:

- distinguere fonte dello stato in futuro, se necessario:

```js
stateSource: "manual" | "system" | "camera"
```

Per ora non va esposto in UI.

Le telecamere potranno in futuro suggerire o verificare lo stato, ma non devono complicare il flusso attuale.

## Test funzionali

### Seduta automatica

1. Creare/importare prenotazione con `tableIds: [3, 4]` e `covers: 6`.
2. Marcare la prenotazione `Seduto`.
3. Verificare:
   - tavolo 3 occupato;
   - tavolo 3 con 6 coperti;
   - tavolo 4 collegato al tavolo 3;
   - nessun modal aperto;
   - `tableStatus = "seduto"`.

### Invio cucina

1. Aggiungere righe alla comanda.
2. Inviare in cucina.
3. Verificare:
   - `status = "Preparazione"`;
   - `tableStatus = "in_preparazione"`;
   - nessuna regressione sul controllo revisione/draft.

### Completamento

1. Completare tutte le righe/sequenze in cucina.
2. Chiudere le sequenze dove previsto.
3. Verificare:
   - `status = "Completato"`;
   - `tableStatus = "completato"`;
   - storico cucina invariato.

### Liberazione

1. Liberare o chiudere il tavolo.
2. Verificare:
   - righe pulite;
   - coperti puliti;
   - collegamenti tavoli rimossi;
   - `tableStatus = "libero"`;
   - `seatedReservationId = null`.

### Concorrenza

Ripetere il test delicato indicato in `PROJECT_CONTEXT.md`:

1. Istanza A apre tavolo e modifica senza inviare.
2. Il lock scade.
3. Istanza B modifica e invia in cucina.
4. A tenta di inviare.
5. A deve essere bloccata e non deve cancellare le righe di B.

## File principali

- `app/gestione-comande-ristorante.html`
- `app/server.js`
- `Reservations.html`
- `PROJECT_CONTEXT.md`

