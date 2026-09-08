CREATE TABLE restaurant_platform_config (
    config_key VARCHAR(32) NOT NULL PRIMARY KEY,
    config_payload JSON NOT NULL,
    updated_at_utc DATETIME NOT NULL,
    CONSTRAINT chk_restaurant_platform_config_json CHECK (JSON_VALID(config_payload))
);
