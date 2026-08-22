USE `Sql467031_5`;

-- Migrazione da eseguire una sola volta sulla tabella gia' creata.
-- Il tipo viene letto dal payload, non duplicato come valore applicativo.
ALTER TABLE restaurant_table_history
    ADD COLUMN entity_type VARCHAR(32) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.history_entity_type'))) STORED,
    ADD INDEX ix_history_entity_type (entity_type);
