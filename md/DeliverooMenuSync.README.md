# Sincronizzazione menu Deliveroo

Il file `DeliverooMenuSync.ashx` legge categorie e prodotti attivi dal database configurato in `MySqlConnectionString`.

## Configurazione `web.config`

Aggiungere questi valori dentro `<appSettings>` senza inserire le credenziali nel repository:

```xml
<add key="DeliverooSiteId" value="101" />
<add key="DeliverooBrandId" value="IL_BRAND_ID_SANDBOX" />
<add key="DeliverooMenuId" value="thai-princess-sandbox-menu" />
<add key="DeliverooMenuName" value="Thai Princess Sandbox Menu" />
<add key="DeliverooMenuImageUrl" value="https://thaiprincess.it/Content/menu-cover.jpg" />
<add key="DeliverooClientId" value="IL_CLIENT_ID" />
<add key="DeliverooClientSecret" value="IL_CLIENT_SECRET" />
<add key="DeliverooMenuSyncKey" value="UNA_CHIAVE_LUNGA_CASUALE" />
```

`DeliverooMenuId` deve rimanere uguale agli aggiornamenti successivi. Con lo stesso ID l'API aggiorna il menu; non serve cancellare manualmente il menu dummy prima dell'upload.

`DeliverooMenuImageUrl` deve essere un URL HTTPS pubblico che restituisce direttamente un'immagine JPEG o PNG. Sostituire l'esempio con un'immagine realmente presente sul dominio.

Per provare un ordine con gli ID del menu, aggiungere anche:

```xml
<add key="DeliverooTestOrderKey" value="UNA_SECONDA_CHIAVE_CASUALE" />
```

Caricare `DeliverooTestOrder.ashx`, quindi aprire:
`https://thaiprincess.it/DeliverooTestOrder.ashx?key=UNA_SECONDA_CHIAVE_CASUALE`

## Procedura

1. Caricare `DeliverooMenuSync.ashx` nella stessa applicazione ASP.NET di `MenuService.asmx`.
2. Verificare l'anteprima aprendo:
   `https://thaiprincess.it/DeliverooMenuSync.ashx?mode=preview`
3. Verificare il menu effettivamente salvato su Deliveroo:
   `https://thaiprincess.it/DeliverooMenuSync.ashx?mode=get`
4. Controllare che il JSON contenga il menu reale e non il dummy.
5. Eseguire l'upload una sola volta:
   `https://thaiprincess.it/DeliverooMenuSync.ashx?mode=upload&key=UNA_CHIAVE_LUNGA_CASUALE`
6. Attendere l'evento di menu webhook e verificare il risultato nel log `deliveroo_webhook_log`.

L'upload è intenzionalmente esplicito e soggetto al limite Deliveroo di una richiesta al minuto per sito. Le immagini e le opzioni ingredienti richiedono un successivo mapping dedicato se devono essere pubblicate anche su Deliveroo.
