USE `Sql467031_5`;

CREATE TABLE IF NOT EXISTS deliveroo_process_log (
    id BIGINT NOT NULL AUTO_INCREMENT,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    log_level VARCHAR(20) NOT NULL DEFAULT 'ERROR',
    message LONGTEXT NOT NULL,
    PRIMARY KEY (id),
    INDEX ix_deliveroo_process_log_created (created_at_utc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
