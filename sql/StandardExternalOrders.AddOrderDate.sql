USE `Sql467031_5`;

ALTER TABLE external_order
    ADD COLUMN order_date DATE
        GENERATED ALWAYS AS (
            CAST(
                NULLIF(
                    NULLIF(
                        JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.date')),
                        ''
                    ),
                    'null'
                ) AS DATE
            )
        ) STORED,
    ADD INDEX ix_external_order_order_date (order_date);
