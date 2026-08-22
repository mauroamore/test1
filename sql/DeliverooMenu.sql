USE `Sql467031_5`;

CREATE TABLE IF NOT EXISTS deliveroo_menu_mapping (
    id BIGINT NOT NULL AUTO_INCREMENT,
    site_id VARCHAR(100) NOT NULL,
    deliveroo_item_id VARCHAR(150) NOT NULL,
    deliveroo_modifier_id VARCHAR(150) NULL,
    local_product_id INT NULL,
    local_ingredient_id INT NULL,
    external_name VARCHAR(255) NULL,
    active TINYINT(1) NOT NULL DEFAULT 1,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_deliveroo_menu_item (site_id, deliveroo_item_id, deliveroo_modifier_id),
    INDEX ix_deliveroo_menu_local_product (local_product_id),
    INDEX ix_deliveroo_menu_local_ingredient (local_ingredient_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS deliveroo_menu_sync (
    id BIGINT NOT NULL AUTO_INCREMENT,
    site_id VARCHAR(100) NOT NULL,
    brand_id VARCHAR(150) NOT NULL,
    menu_id VARCHAR(150) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    response_payload LONGTEXT NULL,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_deliveroo_menu_sync (site_id, menu_id),
    INDEX ix_deliveroo_menu_sync_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO deliveroo_menu_mapping
    (site_id, deliveroo_item_id, deliveroo_modifier_id, external_name)
VALUES
    ('101', 'MU11001', NULL, 'Chicken Burger'),
    ('101', 'MU11001', 'OM1', 'Mayo Sauce')
ON DUPLICATE KEY UPDATE
    external_name = VALUES(external_name),
    updated_at_utc = CURRENT_TIMESTAMP;
