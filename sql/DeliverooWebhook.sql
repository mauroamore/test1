USE `Sql467031_5`;

CREATE TABLE IF NOT EXISTS deliveroo_webhook_log (
    id BIGINT NOT NULL AUTO_INCREMENT,
    received_at_utc DATETIME NOT NULL,
    request_path VARCHAR(500) NULL,
    request_headers TEXT NULL,
    payload LONGTEXT NOT NULL,
    processed TINYINT(1) NOT NULL DEFAULT 0,
    processed_at_utc DATETIME NULL,
    PRIMARY KEY (id),
    INDEX ix_deliveroo_webhook_processed (processed),
    INDEX ix_deliveroo_webhook_received (received_at_utc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
