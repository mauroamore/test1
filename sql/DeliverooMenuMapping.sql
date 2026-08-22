USE `Sql467031_5`;

-- Match Deliveroo items to local products by name.
UPDATE deliveroo_menu_mapping dm
JOIN v2_products p ON LOWER(TRIM(p.name)) = LOWER(TRIM(dm.external_name))
SET dm.local_product_id = p.id,
    dm.updated_at_utc = UTC_TIMESTAMP()
WHERE dm.site_id = '101'
  AND dm.deliveroo_modifier_id IS NULL;

-- Match Deliveroo modifiers to local ingredients by English name.
UPDATE deliveroo_menu_mapping dm
JOIN v2_ingredients i ON LOWER(TRIM(i.name_en)) = LOWER(TRIM(dm.external_name))
SET dm.local_ingredient_id = i.id,
    dm.updated_at_utc = UTC_TIMESTAMP()
WHERE dm.site_id = '101'
  AND dm.deliveroo_modifier_id IS NOT NULL;

-- Review unresolved mappings before enabling order import.
SELECT id, site_id, deliveroo_item_id, deliveroo_modifier_id, external_name,
       local_product_id, local_ingredient_id
FROM deliveroo_menu_mapping
WHERE site_id = '101'
  AND (
    (deliveroo_modifier_id IS NULL AND local_product_id IS NULL)
    OR (deliveroo_modifier_id IS NOT NULL AND local_ingredient_id IS NULL)
  );

-- Mapping degli ID usati dal menu Deliveroo sandbox per il test reale.
INSERT INTO deliveroo_menu_mapping
    (site_id, deliveroo_item_id, deliveroo_modifier_id, local_product_id, external_name, active)
SELECT '101', CONCAT('MU', p.id), NULL, p.id, p.name, 1
FROM v2_products p
WHERE p.id IN (1, 2)
ON DUPLICATE KEY UPDATE
    local_product_id = VALUES(local_product_id),
    external_name = VALUES(external_name),
    active = 1,
    updated_at_utc = UTC_TIMESTAMP();

INSERT INTO deliveroo_menu_mapping
    (site_id, deliveroo_item_id, deliveroo_modifier_id, local_ingredient_id, external_name, active)
    SELECT '101', 'MU1', 'OM1', i.id, i.name_en, 1
FROM v2_ingredients i
WHERE LOWER(TRIM(i.name_en)) = 'mayo sauce'
LIMIT 1
ON DUPLICATE KEY UPDATE
    local_ingredient_id = VALUES(local_ingredient_id),
    external_name = VALUES(external_name),
    active = 1,
    updated_at_utc = UTC_TIMESTAMP();
