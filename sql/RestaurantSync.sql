USE `Sql467031_5`;

-- Definisce i tipi di turno (es. "Servizio" 18->3, in futuro anche "Pranzo" 12->15 ecc.). Non si
-- aggiorna mai una riga esistente quando cambiano gli orari: se ne crea una nuova e si marca la
-- vecchia is_active=0, cosi' le istantanee passate restano legate agli orari che erano davvero in
-- vigore quando sono state create (lo storico non viene riscritto da una modifica successiva).
CREATE TABLE IF NOT EXISTS restaurant_turno_types (
    id INT NOT NULL AUTO_INCREMENT,
    label VARCHAR(64) NOT NULL,
    start_hour TINYINT NOT NULL,
    end_hour TINYINT NOT NULL,
    is_active TINYINT(1) NOT NULL DEFAULT 1,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Una riga per ogni turno effettivamente avvenuto (non piu' una singola riga sovrascritta ad ogni
-- push): turno_type_id + turno_start identificano IL turno specifico. freed_log e' l'array JSON
-- dei liberati durante quel turno; state_payload e' l'ultima istantanea nota per quel turno.
-- restaurant_freed_log sotto resta comunque il log permanente, senza limiti temporali.
CREATE TABLE IF NOT EXISTS restaurant_state_snapshot (
    id BIGINT NOT NULL AUTO_INCREMENT,
    turno_type_id INT NULL,
    turno_start DATETIME NULL,
    state_payload LONGTEXT NOT NULL,
    freed_log LONGTEXT NULL,
    updated_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX ix_turno_start (turno_start)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Da eseguire una tantum sulla tabella gia' esistente in produzione, che aveva ancora la vecchia
-- forma a riga singola (id fisso = 1, colonna Data invece di turno_type_id/turno_start):
-- ALTER TABLE restaurant_state_snapshot ADD COLUMN turno_type_id INT NULL;
-- ALTER TABLE restaurant_state_snapshot ADD COLUMN turno_start DATETIME NULL;
-- ALTER TABLE restaurant_state_snapshot MODIFY COLUMN id BIGINT NOT NULL AUTO_INCREMENT;
-- ALTER TABLE restaurant_state_snapshot DROP COLUMN Data;
-- ALTER TABLE restaurant_state_snapshot ADD INDEX ix_turno_start (turno_start);
-- INSERT INTO restaurant_turno_types (label, start_hour, end_hour) VALUES ('Servizio', 18, 3);

CREATE TABLE IF NOT EXISTS restaurant_command_queue (
    id BIGINT NOT NULL AUTO_INCREMENT,
    client_command_id VARCHAR(64) NOT NULL,
    created_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    command_json LONGTEXT NOT NULL,
    applied_at_utc DATETIME NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_restaurant_command_client_id (client_command_id),
    INDEX ix_restaurant_command_applied (applied_at_utc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS restaurant_freed_log (
    id BIGINT NOT NULL AUTO_INCREMENT,
    entity_type VARCHAR(16) NOT NULL,
    entity_id VARCHAR(64) NOT NULL,
    label VARCHAR(255) NULL,
    payload_json LONGTEXT NULL,
    freed_at_utc DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Storico append-only di tavoli, ordini e pickup chiusi. Il payload e' la fonte unica.
-- UUID e timestamp vengono inseriti nel JSON dalla singola INSERT atomica; id, table_id
-- e closed_at_utc sono colonne generate per ricerche e indici.
CREATE TABLE IF NOT EXISTS restaurant_table_history (
    payload_json JSON NOT NULL,
    id CHAR(36) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.history_id'))) STORED,
    entity_type VARCHAR(32) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.history_entity_type'))) STORED,
    table_id VARCHAR(64) GENERATED ALWAYS AS
        (JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.id'))) STORED,
    closed_at_utc DATETIME GENERATED ALWAYS AS
        (CAST(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$._closed_at_utc')) AS DATETIME)) STORED,
    PRIMARY KEY (id),
    INDEX ix_history_entity_type (entity_type),
    INDEX ix_table_history_table (table_id),
    INDEX ix_table_history_closed (closed_at_utc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
