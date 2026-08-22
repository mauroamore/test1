USE `Sql467031_5`;

CREATE TABLE IF NOT EXISTS deliveroo_order (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id VARCHAR(180) NOT NULL,
    order_number VARCHAR(100) NULL,
    display_id VARCHAR(100) NULL,
    location_id VARCHAR(100) NULL,
    brand_id VARCHAR(150) NULL,
    status VARCHAR(50) NULL,
    fulfillment_type VARCHAR(50) NULL,
    total_fractional BIGINT NULL,
    currency_code VARCHAR(10) NULL,
    is_tabletless TINYINT(1) NULL,
    order_payload LONGTEXT NOT NULL,
    first_received_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_received_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_deliveroo_order_external_id (external_order_id),
    INDEX ix_deliveroo_order_status (status),
    INDEX ix_deliveroo_order_location (location_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS deliveroo_order_modifier (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id VARCHAR(180) NOT NULL,
    line_number INT NOT NULL,
    modifier_number INT NOT NULL,
    pos_item_id VARCHAR(100) NOT NULL,
    local_ingredient_id INT NULL,
    modifier_name VARCHAR(255) NULL,
    quantity DECIMAL(10,2) NOT NULL DEFAULT 0,
    unit_price_fractional BIGINT NULL,
    total_price_fractional BIGINT NULL,
    modifier_payload LONGTEXT NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_deliveroo_modifier (external_order_id, line_number, modifier_number),
    INDEX ix_deliveroo_modifier_ingredient (local_ingredient_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS deliveroo_order_item (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id VARCHAR(180) NOT NULL,
    line_number INT NOT NULL,
    pos_item_id VARCHAR(100) NOT NULL,
    local_product_id INT NULL,
    item_name VARCHAR(255) NULL,
    quantity DECIMAL(10,2) NOT NULL DEFAULT 0,
    unit_price_fractional BIGINT NULL,
    total_price_fractional BIGINT NULL,
    modifiers_json LONGTEXT NULL,
    item_payload LONGTEXT NOT NULL,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_deliveroo_order_item_line (external_order_id, line_number),
    INDEX ix_deliveroo_order_item_product (local_product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
