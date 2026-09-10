USE `Sql467031_5`;

CREATE TABLE IF NOT EXISTS restaurant_device_settings_snapshot (
    id BIGINT NOT NULL AUTO_INCREMENT,
    snapshot_name VARCHAR(128) NOT NULL,
    settings_payload JSON NOT NULL,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_device_settings_snapshot_name (snapshot_name),
    INDEX ix_device_settings_snapshot_updated (updated_at_utc),
    CONSTRAINT chk_device_settings_snapshot_json CHECK (JSON_VALID(settings_payload))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
