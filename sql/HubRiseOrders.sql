USE `Sql467031_5`;

CREATE TABLE IF NOT EXISTS hubrise_order (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id VARCHAR(180) NOT NULL,
    location_id VARCHAR(100) NULL,
    status VARCHAR(50) NULL,
    service_type VARCHAR(50) NULL,
    customer_name VARCHAR(255) NULL,
    total_fractional BIGINT NULL,
    currency_code VARCHAR(10) NULL,
    collection_code VARCHAR(50) NULL,
    channel VARCHAR(100) NULL,
    order_payload LONGTEXT NOT NULL,
    first_received_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_received_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fetched_by_pos_at_utc DATETIME NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_hubrise_order_external_id (external_order_id),
    INDEX ix_hubrise_order_status (status),
    INDEX ix_hubrise_order_location (location_id),
    INDEX ix_hubrise_order_fetched (fetched_by_pos_at_utc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS hubrise_order_item (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id VARCHAR(180) NOT NULL,
    line_number INT NOT NULL,
    hubrise_ref VARCHAR(100) NULL,
    item_name VARCHAR(255) NULL,
    quantity DECIMAL(10,2) NOT NULL DEFAULT 0,
    unit_price_fractional BIGINT NULL,
    total_price_fractional BIGINT NULL,
    options_json LONGTEXT NULL,
    item_payload LONGTEXT NOT NULL,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_hubrise_order_item_line (external_order_id, line_number)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS hubrise_order_option (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id VARCHAR(180) NOT NULL,
    line_number INT NOT NULL,
    option_number INT NOT NULL,
    hubrise_ref VARCHAR(100) NULL,
    option_name VARCHAR(255) NULL,
    quantity DECIMAL(10,2) NOT NULL DEFAULT 0,
    price_fractional BIGINT NULL,
    option_payload LONGTEXT NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_hubrise_order_option (external_order_id, line_number, option_number)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
