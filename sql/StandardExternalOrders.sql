USE `Sql467031_5`;

-- Schema comune per tutti gli ordini esterni (Sigonella, HubRise e integrazioni future).
-- Il JSON completo in order_payload contiene items, senza una tabella linee duplicata.

CREATE TABLE IF NOT EXISTS external_order (
    id BIGINT NOT NULL AUTO_INCREMENT,
    source VARCHAR(32) NOT NULL DEFAULT 'sigonella',
    channel VARCHAR(100) NOT NULL DEFAULT 'Sigonella',
    external_order_id VARCHAR(180) NOT NULL,
    order_number VARCHAR(100) NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'new',
    service_type VARCHAR(32) NOT NULL DEFAULT 'delivery',
    customer_name VARCHAR(255) NULL,
    customer_email VARCHAR(255) NULL,
    customer_phone VARCHAR(64) NULL,
    location_id VARCHAR(100) NULL,
    total DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    currency_code VARCHAR(10) NOT NULL DEFAULT 'EUR',
    order_notes TEXT NULL,
    order_payload LONGTEXT NOT NULL,
    first_received_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    confirmed_at_utc DATETIME NULL,
    imported_at_utc DATETIME NULL,
    price_updated_at_utc DATETIME NULL,
    customer_notified_at_utc DATETIME NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_external_order_source_id (source, external_order_id),
    INDEX ix_external_order_status (status),
    INDEX ix_external_order_date (first_received_at_utc),
    INDEX ix_external_order_imported (imported_at_utc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS external_order_event (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id BIGINT NOT NULL,
    event_type VARCHAR(64) NOT NULL,
    old_status VARCHAR(32) NULL,
    new_status VARCHAR(32) NULL,
    event_payload LONGTEXT NULL,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX ix_external_order_event_order (external_order_id),
    INDEX ix_external_order_event_type (event_type),
    CONSTRAINT fk_external_order_event_order
        FOREIGN KEY (external_order_id) REFERENCES external_order(id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Stati previsti dal progetto parallelo:
-- new -> confirmed -> imported -> reviewed -> price_updated -> notified -> sent_to_kitchen
-- Gli stati di annullamento e chiusura restano finali e vengono registrati anche negli eventi.
