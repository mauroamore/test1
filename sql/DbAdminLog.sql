USE `Sql467031_5`;

CREATE TABLE IF NOT EXISTS db_admin_log (
    id BIGINT NOT NULL AUTO_INCREMENT,
    executed_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sql_text LONGTEXT NOT NULL,
    success TINYINT(1) NOT NULL,
    rows_affected_or_returned INT NULL,
    error_message LONGTEXT NULL,
    PRIMARY KEY (id),
    INDEX ix_db_admin_log_executed (executed_at_utc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
