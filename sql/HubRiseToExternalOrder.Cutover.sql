USE `Sql467031_5`;

-- Cutover HubRise -> external_order.
-- Eseguire solo dopo aver pubblicato il nuovo HubRiseWebhook/HubRiseOrdersFeed e
-- aver verificato almeno un ordine end-to-end. I dati HubRise storici sono provvisori.

-- Il nuovo webhook scrive in external_order; il feed legge external_order.order_payload.
-- Non esiste una migrazione delle righe: items resta nel JSON originale.

DROP TABLE IF EXISTS external_order_line;
DROP TABLE IF EXISTS hubrise_order_option;
DROP TABLE IF EXISTS hubrise_order_item;
DROP TABLE IF EXISTS hubrise_order;
