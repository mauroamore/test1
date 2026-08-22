CREATE TABLE IF NOT EXISTS pos_device_presence (
    device_id VARCHAR(120) NOT NULL,
    app_version VARCHAR(80) NULL,
    last_seen_utc DATETIME NOT NULL,
    PRIMARY KEY (device_id),
    INDEX ix_pos_presence_last_seen (last_seen_utc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS pos_payment_transaction (
    id BIGINT NOT NULL AUTO_INCREMENT,
    transaction_id VARCHAR(180) NOT NULL,
    device_id VARCHAR(120) NOT NULL,
    order_id VARCHAR(180) NOT NULL,
    payment_payload JSON NOT NULL,
    status VARCHAR(40) NOT NULL DEFAULT 'pending',
    receipt_payload JSON NULL,
    error_code VARCHAR(100) NULL,
    error_message VARCHAR(500) NULL,
    created_at_utc DATETIME NOT NULL,
    updated_at_utc DATETIME NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_pos_payment_transaction (transaction_id),
    INDEX ix_pos_payment_pending (device_id, status, created_at_utc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
