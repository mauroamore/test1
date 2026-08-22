USE `Sql467031_5`;

-- order_payload remains the single source of truth.
-- Keep the generated column for fast filtering/display, but use the same
-- general-note field as HubRise: notes. Item notes remain inside items[].notes.
ALTER TABLE external_order
    MODIFY COLUMN order_notes VARCHAR(1000)
        GENERATED ALWAYS AS (
            NULLIF(JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.notes')), '')
        ) STORED;
