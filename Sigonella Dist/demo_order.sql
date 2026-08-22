CREATE TABLE IF NOT EXISTS demo_order (
    id BIGINT NOT NULL AUTO_INCREMENT,
    external_order_id VARCHAR(180) NOT NULL,
    order_payload LONGTEXT NOT NULL,
    status VARCHAR(40) NOT NULL DEFAULT 'confirmed',
    payment_status VARCHAR(40) NOT NULL DEFAULT 'unpaid',
    created_at_utc TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at_utc TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_demo_order_external_id (external_order_id),
    KEY ix_demo_order_status (status, payment_status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DELETE FROM demo_order;

INSERT INTO demo_order (external_order_id, order_payload, status, payment_status)
VALUES
('DEMO-ORDER-0001', '{"id":"DEMO-ORDER-0001","uuid":"DEMO-ORDER-0001","external_order_id":"DEMO-ORDER-0001","tho":{"date":"2099-01-01","location":"0","location_name":"Residence Marinai","status":"confirmed","notes":"Ordine dimostrativo Nexi"},"items":[{"id":1,"name":"1 Thung Tong","product_name":"1 Thung Tong","quantity":1,"count":1,"price":7.00,"unit_price":7.00,"customer_notes":""},{"id":27,"name":"2 Tod Man Muu","product_name":"2 Tod Man Muu","quantity":1,"count":1,"price":7.00,"unit_price":7.00,"customer_notes":""}],"stato":2,"total":14.00,"status":"confirmed","payment_status":"unpaid","channel":"Nexi Demo","customer":{"first_name":"Cliente Demo Nexi","last_name":"","email":"demo@nexi.test","phone":""},"currency":"EUR"}', 'confirmed', 'unpaid');
