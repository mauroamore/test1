CREATE TABLE IF NOT EXISTS pos_order_lock (
    order_id VARCHAR(180) NOT NULL PRIMARY KEY,
    lock_token CHAR(36) NOT NULL,
    terminal_id VARCHAR(120) NOT NULL,
    expires_at_utc DATETIME NOT NULL,
    created_at_utc TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_pos_order_lock_expiry (expires_at_utc)
);
