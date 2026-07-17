-- =============================================================================
-- callstats-grafana / АТС / 02_migrate_disposition.sql
--
-- Расширяет queue_daily новыми колонками для честного учёта "несостоявшихся":
--   exit_timeout   — звонки, вышедшие по таймауту очереди
--   exit_empty     — звонки, попавшие в пустую очередь
--   not_completed  — суммарно: ABANDON + EXITWITHTIMEOUT + EXITEMPTY
--
-- Скрипт идемпотентный (IF NOT EXISTS), запускается один раз при обновлении
-- существующей инсталляции. Запуск от root MariaDB или от writer'а с ALTER.
-- =============================================================================

USE callstats;

ALTER TABLE queue_daily
  ADD COLUMN IF NOT EXISTS exit_timeout  INT NOT NULL DEFAULT 0 AFTER abandoned,
  ADD COLUMN IF NOT EXISTS exit_empty    INT NOT NULL DEFAULT 0 AFTER exit_timeout,
  ADD COLUMN IF NOT EXISTS not_completed INT NOT NULL DEFAULT 0 AFTER exit_empty;

SHOW COLUMNS FROM queue_daily;
