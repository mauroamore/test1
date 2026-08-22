USE `Sql467031_5`;

-- Schema definitivo: order_payload e' la fonte unica dei dati dell'ordine.
-- Le tabelle di dettaglio non sono necessarie: le righe restano nel JSON.
SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS external_order_event;
DROP TABLE IF EXISTS external_order_line;
DROP TABLE IF EXISTS external_order;
SET FOREIGN_KEY_CHECKS = 1;

CREATE TABLE external_order (
    id BIGINT NOT NULL AUTO_INCREMENT,
    source VARCHAR(32) NOT NULL DEFAULT 'sigonella',
    order_payload JSON NOT NULL,

    channel VARCHAR(100)
        GENERATED ALWAYS AS (COALESCE(
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.channel')), ''),
            'Sigonella'
        )) STORED,

    external_order_id VARCHAR(180)
        GENERATED ALWAYS AS (COALESCE(
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.uuid')), ''),
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.id')), '')
        )) STORED,
    order_number VARCHAR(100)
        GENERATED ALWAYS AS (NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.order_number')), '')) STORED,
    order_date DATE
        GENERATED ALWAYS AS (CAST(
            NULLIF(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.date')), ''), 'null')
            AS DATE
        )) STORED,
    status VARCHAR(32)
        GENERATED ALWAYS AS (COALESCE(
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.status')), ''),
            CASE
                WHEN CAST(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.stato')) AS UNSIGNED) >= 2 THEN 'confirmed'
                WHEN JSON_EXTRACT(order_payload, '$.stato') IS NOT NULL THEN 'new'
                ELSE 'new'
            END
        )) STORED,
    service_type VARCHAR(32)
        GENERATED ALWAYS AS (COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.service_type')), ''), 'delivery')) STORED,
    customer_name VARCHAR(255)
        GENERATED ALWAYS AS (NULLIF(CONCAT_WS(' ',
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.customer.first_name')), ''),
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.customer.last_name')), '')
        ), '')) STORED,
    customer_email VARCHAR(255)
        GENERATED ALWAYS AS (NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.customer.email')), '')) STORED,
    customer_phone VARCHAR(64)
        GENERATED ALWAYS AS (NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.customer.phone')), '')) STORED,
    location_id VARCHAR(100)
        GENERATED ALWAYS AS (COALESCE(
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.location_id')), ''),
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.location')), '')
        )) STORED,
    total DECIMAL(12,2)
        GENERATED ALWAYS AS (COALESCE(
            CAST(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.total')) AS DECIMAL(12,2)),
            CAST(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.totale')) AS DECIMAL(12,2)),
            0
        )) STORED,
    currency_code VARCHAR(10)
        GENERATED ALWAYS AS (COALESCE(
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.currency')), ''),
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.currency_code')), ''),
            'EUR'
        )) STORED,
    order_notes VARCHAR(1000)
        GENERATED ALWAYS AS (COALESCE(
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.notes')), ''),
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.order_notes')), '')
        )) STORED,

    first_received_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    confirmed_at_utc DATETIME NULL,
    imported_at_utc DATETIME NULL,
    price_updated_at_utc DATETIME NULL,
    customer_notified_at_utc DATETIME NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_external_order_source_id (source, external_order_id),
    INDEX ix_external_order_status (status),
    INDEX ix_external_order_channel (channel),
    INDEX ix_external_order_order_date (order_date),
    INDEX ix_external_order_date (first_received_at_utc),
    INDEX ix_external_order_imported (imported_at_utc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE external_order_event (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id BIGINT NOT NULL,
    event_type VARCHAR(64) NOT NULL,
    old_status VARCHAR(32) NULL,
    new_status VARCHAR(32) NULL,
    event_payload JSON NULL,
    notification_status VARCHAR(16) NULL,
    notification_sent_at_utc DATETIME NULL,
    notification_error TEXT NULL,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX ix_external_order_event_order (external_order_id),
    CONSTRAINT fk_external_order_event_order FOREIGN KEY (external_order_id)
        REFERENCES external_order(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
