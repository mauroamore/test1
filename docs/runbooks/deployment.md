# Runbook di deployment

Questo documento descrive il percorso operativo senza contenere credenziali o dati live. Prima di eseguire un publish verificare sempre il componente interessato e annotare la versione pubblicata.

## Componenti

- **Sviluppo**: `C:\Users\Mauro\Dropbox\vorrei`
- **Server Node locale**: `server.js`, avviato tramite una copia locale dei parametri di `Start.example.ps1`
- **Sito e bridge remoto**: handler ASP.NET/ASHX e `RestaurantSync` su `thaiprincess.it`
- **POS Nexi**: progetto Android in `D:\Documenti\ChatGPT\GoDaddy`

## Prima del deployment

1. Leggere `md/PROJECT_STATUS.md` e `handoff/PROJECT_CONTEXT.md` come fonti storiche e verificare che non ci siano modifiche operative in corso.
2. Eseguire `npm.cmd run check` dalla root del progetto. Il controllo verifica la sintassi del server e degli script inline principali.
3. Verificare che i file di configurazione locali derivino da `Start.example.ps1`, senza aggiungere segreti al repository.
4. Separare sempre codice, dati provvisori, log e artifact di build.

## Server Node locale

Avviare con i parametri locali non versionati. Una modifica a `server.js` richiede il riavvio del processo per avere effetto.

Prima di riavviare, annotare l'orario e verificare che non ci sia un flusso operativo da preservare. Al momento non è stato confermato un uso reale in sala/cucina, ma questa assunzione va ricontrollata prima di ogni operazione.

## Pubblicazione web/ASP.NET

1. Preparare una directory di publish pulita e verificare il contenuto.
2. Usare il bridge di upload già presente nel progetto, mantenendo la password FTP fuori dal repository e fuori dai log.
3. Pubblicare solo la coppia locale/remota prevista dal componente.
4. Annotare timestamp, file o versione pubblicata e risultato del controllo remoto.

## RestaurantSync

Il codice server è stato sviluppato specificamente per questo progetto. Le modifiche non impattano altri ambienti produttivi, ma possono modificare il collegamento tra il locale e `thaiprincess.it`.

Dopo una modifica verificare separatamente:

- raggiungibilità dell'endpoint remoto;
- autenticazione senza stampare la chiave;
- invio e ricezione di una fixture sanificata;
- assenza di duplicazioni nella coda locale.

## POS Nexi

Il POS è un progetto distinto. Prima di una build verificare il progetto Gradle in `D:\Documenti\ChatGPT\GoDaddy`, la configurazione locale dell'SDK e il target del terminale. Non confondere una build del POS con una pubblicazione del server Node o degli handler web.

## Rollback

Prima del publish conservare una copia timestampata dell'artefatto precedente e annotare il percorso. In caso di errore:

1. interrompere il publish successivo;
2. ripristinare l'artefatto precedente dello stesso componente;
3. riavviare il componente solo se richiesto dalla piattaforma;
4. eseguire il controllo minimo e annotare causa, versione ripristinata e risultato.

## Credenziali e dati

Password, chiavi, token, `ristorante-state.json`, log e dump non devono essere copiati in documentazione, fixture o pacchetti di handoff. Per test e diagnosi usare fixture sanificate.
