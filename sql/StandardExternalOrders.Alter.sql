USE `Sql467031_5`;

-- Aggiornamento incrementale dello schema standard.
-- Non modifica la tabella sigonella.

ALTER TABLE external_order
    MODIFY COLUMN updated_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

ALTER TABLE external_order_event
    ADD COLUMN notification_status VARCHAR(16) NULL AFTER event_payload,
    ADD COLUMN notification_sent_at_utc DATETIME NULL AFTER notification_status,
    ADD COLUMN notification_error TEXT NULL AFTER notification_sent_at_utc,
    ADD INDEX ix_external_order_event_notification (notification_status);

-- Stati applicativi previsti dal servizio parallelo:
-- new, pending, confirmed, imported, reviewed, price_updated,
-- ready_for_pickup, rejected, cancelled, sent_to_kitchen, closed.

-- Esempi di eventi:
-- customer_updated, confirmed, price_updated, ready_for_pickup,
-- rejected, cancelled, customer_arrived.
