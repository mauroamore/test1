USE `Sql467031_5`;

-- HubRise identifies the originating platform with channel.
-- The payload remains authoritative; this column is only a fast filter/index.
SET @has_channel := (
    SELECT COUNT(*)
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'external_order'
      AND COLUMN_NAME = 'channel'
);

SET @sql := IF(
    @has_channel = 0,
    'ALTER TABLE external_order ADD COLUMN channel VARCHAR(100) NOT NULL DEFAULT ''Sigonella'', ADD INDEX ix_external_order_channel (channel)',
    'SELECT 1'
);
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

UPDATE external_order
SET channel = COALESCE(
    NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.channel')), ''),
    'Sigonella'
)
WHERE channel IS NULL OR channel = '';
