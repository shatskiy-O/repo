-- =============================================================================
-- callstats-grafana / АТС / 01_schema.sql
-- Создание базы callstats, таблиц, пользователей и прав.
-- Запускается ОДИН РАЗ при первичной установке от root MariaDB.
--
-- Перед запуском замените плейсхолдеры:
--   ${CALLSTATS_WRITER_PASS}
--   ${CALLSTATS_RO_PASS}
-- =============================================================================

CREATE DATABASE IF NOT EXISTS callstats
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE callstats;

-- ----------------------------------------------------------------------------
-- queue_calls: одна строка на звонок
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS queue_calls (
  callid       VARCHAR(80)  NOT NULL,
  queuename    VARCHAR(64)  NOT NULL,
  enter_ts     DATETIME     NOT NULL,
  connect_ts   DATETIME     NULL,
  end_ts       DATETIME     NULL,
  agent        VARCHAR(128) NULL,
  disposition  VARCHAR(32)  NOT NULL,
  PRIMARY KEY (callid, queuename),
  KEY idx_enter_ts     (enter_ts),
  KEY idx_queue_enter  (queuename, enter_ts),
  KEY idx_agent_enter  (agent, enter_ts)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- queue_daily: агрегаты за сутки на очередь
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS queue_daily (
  day             DATE         NOT NULL,
  queuename       VARCHAR(64)  NOT NULL,
  offered         INT NOT NULL DEFAULT 0,
  answered        INT NOT NULL DEFAULT 0,
  abandoned       INT NOT NULL DEFAULT 0,
  exit_timeout    INT NOT NULL DEFAULT 0,
  exit_empty      INT NOT NULL DEFAULT 0,
  not_completed   INT NOT NULL DEFAULT 0,
  asa_sec         DOUBLE NULL,
  sla_20_pct      DOUBLE NULL,
  sla_30_pct      DOUBLE NULL,
  PRIMARY KEY (day, queuename)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Пользователи и права
-- ----------------------------------------------------------------------------

-- Writer: используется ETL-скриптом
CREATE USER IF NOT EXISTS 'callstats_writer'@'localhost'
  IDENTIFIED BY '${CALLSTATS_WRITER_PASS}';

GRANT SELECT, INSERT, UPDATE, DELETE,
      CREATE, DROP, ALTER, INDEX, REFERENCES
  ON callstats.* TO 'callstats_writer'@'localhost';

-- Writer читает исходные события из queue_log FreePBX
GRANT SELECT ON asteriskcdrdb.queue_log TO 'callstats_writer'@'localhost';

-- Read-only: используется Grafana через SSH-туннель
CREATE USER IF NOT EXISTS 'callstats_ro'@'%'
  IDENTIFIED BY '${CALLSTATS_RO_PASS}';

GRANT SELECT ON callstats.* TO 'callstats_ro'@'%';

FLUSH PRIVILEGES;

-- ----------------------------------------------------------------------------
-- Проверка
-- ----------------------------------------------------------------------------
SHOW GRANTS FOR 'callstats_writer'@'localhost';
SHOW GRANTS FOR 'callstats_ro'@'%';
SHOW TABLES FROM callstats;
