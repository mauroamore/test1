USE `Sql467031_5`;

CREATE TABLE IF NOT EXISTS restaurant_common_variation (
    id BIGINT NOT NULL AUTO_INCREMENT,
    variation_name VARCHAR(128) NOT NULL,
    price DECIMAL(10,2) NOT NULL DEFAULT 0,
    display_order INT NOT NULL DEFAULT 0,
    background_color CHAR(7) NOT NULL DEFAULT '#e8f3ef',
    is_active TINYINT(1) NOT NULL DEFAULT 1,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_restaurant_common_variation_name (variation_name),
    INDEX ix_restaurant_common_variation_order (is_active, display_order, variation_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
