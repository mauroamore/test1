# ADR 0001: formato comune della comanda

## Stato

Accettata

## Decisione

La comanda comune del sistema usa il formato HubRise come base. La collezione delle pietanze si chiama `items`, anche per gli ordini associati ai tavoli.

I campi HubRise non vengono tradotti né duplicati. Il sistema conserva nomi e significato originali, inclusi `status`, `service_type`, `customer`, `items`, `product_name`, `sku_name`, `price`, `quantity`, `options`, `payments`, `discounts` e `charges`.

I dati operativi specifici del ristorante vivono sotto la radice locale `tho`, a livello di ordine o di singolo item. Esempi: stato cucina, quantità inviata, corso, tavolo, stato tavolo e revisione locale.

## Aggiornamenti da HubRise

HubRise è una sorgente degli ordini. Dopo l’importazione, l’ordine è gestito localmente. Gli aggiornamenti successivi provenienti da HubRise modificano solo i dati che HubRise aggiorna realmente, principalmente lo stato logistico dell’ordine.

Gli articoli importati non vengono sostituiti da un aggiornamento di stato HubRise.

## Conseguenze

- Il backend deve adattare il payload HubRise una sola volta.
- Il frontend deve consumare `items`, senza conoscere dettagli di traduzione del formato.
- `lines` può esistere solo come struttura temporanea di rendering, non come campo della comanda persistita.
- Non vengono inviati a HubRise i dati contenuti in `tho`.
- Gli ordini ai tavoli riusano la stessa struttura degli ordini esterni e aggiungono il contesto locale sotto `tho`.

## Motivazione

HubRise è l’unico formato esterno non controllabile. Usarlo come base riduce duplicazioni, evita trasformazioni inutili e permette di trattare allo stesso modo le righe di un ordine delivery e quelle di una comanda al tavolo.
