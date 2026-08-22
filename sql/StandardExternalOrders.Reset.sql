USE `Sql467031_5`;

-- RESET DELLO SCHEMA PARALLELO.
-- Le tabelle sono vuote: lo script le ricrea con la struttura definitiva.
-- NON elimina e NON modifica la tabella sigonella.

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS external_order_event;
DROP TABLE IF EXISTS external_order_line;
DROP TABLE IF EXISTS external_order;
SET FOREIGN_KEY_CHECKS = 1;

CREATE TABLE external_order (
    id BIGINT NOT NULL AUTO_INCREMENT,
    source VARCHAR(32) NOT NULL DEFAULT 'sigonella-test',
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
    updated_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
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

CREATE TABLE external_order_line (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id BIGINT NOT NULL,
    line_number INT NOT NULL,
    product_id VARCHAR(100) NULL,
    item_name VARCHAR(255) NOT NULL,
    category_name VARCHAR(255) NULL,
    quantity DECIMAL(10,2) NOT NULL DEFAULT 1.00,
    unit_price DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    original_unit_price DECIMAL(12,2) NULL,
    line_total DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    notes TEXT NULL,
    options_payload LONGTEXT NULL,
    line_payload LONGTEXT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_external_order_line (external_order_id, line_number),
    INDEX ix_external_order_line_product (product_id),
    CONSTRAINT fk_external_order_line_order
        FOREIGN KEY (external_order_id) REFERENCES external_order(id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE external_order_event (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id BIGINT NOT NULL,
    event_type VARCHAR(64) NOT NULL,
    old_status VARCHAR(32) NULL,
    new_status VARCHAR(32) NULL,
    event_payload LONGTEXT NULL,
    notification_status VARCHAR(16) NULL,
    notification_sent_at_utc DATETIME NULL,
    notification_error TEXT NULL,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX ix_external_order_event_order (external_order_id),
    INDEX ix_external_order_event_type (event_type),
    INDEX ix_external_order_event_notification (notification_status),
    CONSTRAINT fk_external_order_event_order
        FOREIGN KEY (external_order_id) REFERENCES external_order(id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
