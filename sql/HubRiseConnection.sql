USE `Sql467031_5`;

CREATE TABLE IF NOT EXISTS hubrise_connection (
    id BIGINT NOT NULL AUTO_INCREMENT,
    account_id VARCHAR(100) NULL,
    location_id VARCHAR(100) NULL,
    catalog_id VARCHAR(100) NULL,
    customer_list_id VARCHAR(100) NULL,
    access_token VARCHAR(255) NOT NULL,
    scope VARCHAR(255) NULL,
    connected_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at_utc DATETIME NULL,
    PRIMARY KEY (id),
    INDEX ix_hubrise_connection_active (revoked_at_utc),
    INDEX ix_hubrise_connection_location (location_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
