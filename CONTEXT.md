# Contesto del progetto

## Scopo

`Vorrei` e il sistema di gestione delle comande del ristorante Thai Princess. Coordina il lavoro della sala e della cucina, riceve ordini da integrazioni esterne e comunica con componenti locali e remoti.

## Glossario

- **Comanda**: insieme operativo di articoli da preparare e servire.
- **Ordine esterno**: ordine ricevuto da un canale o servizio remoto, da normalizzare prima di entrare nel modello locale.
- **Stato cucina**: avanzamento della comanda nel flusso di preparazione.
- **Stato tavolo**: condizione operativa del tavolo in sala: `libero`, `prenotato`, `seduto`, `in_preparazione`, `completato`, `chiuso`.
- **Prenotazione**: prenotazione normalizzata associata, quando possibile, a uno o più tavoli.
- **RestaurantSync**: ponte server specifico di questo progetto tra il sistema locale e il servizio remoto sul sito; non è un ambiente produttivo condiviso con altri progetti.
- **HubRise**: integrazione esterna che comprende il flusso attualmente rilevante di Deliveroo.
- **POS Nexi**: applicazione separata ospitata sul terminale Nexi, nel progetto locale `D:\Documenti\ChatGPT\GoDaddy`.

## Confini

La sorgente canonica è `C:\Users\Mauro\Dropbox\vorrei`. La cartella `handoff\app` è un tentativo storico di pulizia e non è una sorgente autorevole.

`RestaurantSync`, il POS Nexi e gli handler remoti appartengono allo stesso sistema operativo, ma restano componenti distinti con procedure proprie.

## Stato delle informazioni

I dati presenti nella tree, inclusi stato operativo, log, export e risultati di test, sono provvisori o storici. Non costituiscono da soli la specifica del dominio.

Deliveroo è fuori dal perimetro attuale come integrazione separata. `nexi-ecr-lan` è un test già integrato e non rappresenta il centro della suite di test.

## Regole di dominio già concordate

- Lo stato cucina e lo stato tavolo sono concetti distinti.
- Una prenotazione attiva può rendere `prenotato` un tavolo libero.
- L'azione `Seduto` assegna i tavoli e i coperti senza richiedere un modal.
- L'apertura di un tavolo con coperti crea una prenotazione locale `walk-in`, visibile anche nella gestione prenotazioni e attiva finche il tavolo non viene liberato.
- Le sovrapposizioni di prenotazioni vengono segnalate, non bloccate automaticamente.
- Le integrazioni esterne vengono trattate tramite adapter e fixture sanificate nei test.
