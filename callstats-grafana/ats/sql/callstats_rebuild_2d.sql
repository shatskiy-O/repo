-- =============================================================================
-- callstats-grafana / АТС / callstats_rebuild_2d.sql
--
-- ETL: перестраивает данные callstats.queue_calls и callstats.queue_daily
-- за последние 48 часов на основании asteriskcdrdb.queue_log.
--
-- Окно 48 ч — чтобы захватить долгоиграющие и отложенные звонки, но при этом
-- перестроение оставалось быстрым.
--
-- Запускается shell-обёрткой callstats_update.sh раз в 5 минут по cron.
--
-- Диспозиции звонков:
--   ANSWERED         — соединение с оператором
--   ABANDON          — звонящий бросил трубку до соединения
--   EXITWITHTIMEOUT  — истёк таймаут очереди
--   EXITEMPTY        — в очереди не было операторов
--   EXITWITHKEY      — звонящий вышел из очереди по DTMF
--   UNKNOWN          — нет финального события (звонок ещё в обработке)
-- =============================================================================

SET @from_ts := NOW() - INTERVAL 2 DAY;

-- Пересобираем окно
DELETE FROM callstats.queue_calls
WHERE enter_ts >= @from_ts;

INSERT INTO callstats.queue_calls
  (callid, queuename, enter_ts, connect_ts, end_ts, agent, disposition)
SELECT
  ql.callid,
  ql.queuename,
  MIN(CASE WHEN ql.event='ENTERQUEUE' THEN ql.time END) AS enter_ts,
  MIN(CASE WHEN ql.event='CONNECT'    THEN ql.time END) AS connect_ts,
  MIN(CASE WHEN ql.event IN (
      'ABANDON','COMPLETEAGENT','COMPLETECALLER',
      'EXITWITHTIMEOUT','EXITEMPTY','EXITWITHKEY'
    ) THEN ql.time END) AS end_ts,
  NULLIF(MAX(CASE WHEN ql.event='CONNECT' THEN ql.agent END), '') AS agent,
  CASE
    WHEN MIN(CASE WHEN ql.event='CONNECT'         THEN ql.time END) IS NOT NULL THEN 'ANSWERED'
    WHEN MIN(CASE WHEN ql.event='ABANDON'         THEN ql.time END) IS NOT NULL THEN 'ABANDON'
    WHEN MIN(CASE WHEN ql.event='EXITWITHTIMEOUT' THEN ql.time END) IS NOT NULL THEN 'EXITWITHTIMEOUT'
    WHEN MIN(CASE WHEN ql.event='EXITEMPTY'       THEN ql.time END) IS NOT NULL THEN 'EXITEMPTY'
    WHEN MIN(CASE WHEN ql.event='EXITWITHKEY'     THEN ql.time END) IS NOT NULL THEN 'EXITWITHKEY'
    ELSE 'UNKNOWN'
  END AS disposition
FROM asteriskcdrdb.queue_log ql
WHERE ql.time >= @from_ts
  AND ql.queuename IS NOT NULL
  AND ql.queuename <> ''
  AND ql.queuename <> 'NONE'
  AND ql.event IN (
    'ENTERQUEUE','CONNECT',
    'ABANDON','COMPLETEAGENT','COMPLETECALLER',
    'EXITWITHTIMEOUT','EXITEMPTY','EXITWITHKEY'
  )
GROUP BY ql.callid, ql.queuename
HAVING MIN(CASE WHEN ql.event='ENTERQUEUE' THEN ql.time END) IS NOT NULL;

-- Дневные агрегаты за окно
DELETE FROM callstats.queue_daily
WHERE day >= CURDATE() - INTERVAL 2 DAY;

INSERT INTO callstats.queue_daily
  (day, queuename,
   offered, answered, abandoned,
   exit_timeout, exit_empty, not_completed,
   asa_sec, sla_20_pct, sla_30_pct)
SELECT
  DATE(enter_ts)                                                     AS day,
  queuename,
  COUNT(*)                                                           AS offered,
  SUM(disposition = 'ANSWERED')                                      AS answered,
  SUM(disposition = 'ABANDON')                                       AS abandoned,
  SUM(disposition = 'EXITWITHTIMEOUT')                               AS exit_timeout,
  SUM(disposition = 'EXITEMPTY')                                     AS exit_empty,
  SUM(disposition IN ('ABANDON','EXITWITHTIMEOUT','EXITEMPTY'))      AS not_completed,
  AVG(CASE WHEN disposition='ANSWERED' AND connect_ts IS NOT NULL
           THEN TIMESTAMPDIFF(SECOND, enter_ts, connect_ts) END)     AS asa_sec,
  100.0 * AVG(CASE
                WHEN disposition='ANSWERED' AND connect_ts IS NOT NULL
                 AND TIMESTAMPDIFF(SECOND, enter_ts, connect_ts) <= 20 THEN 1
                ELSE 0
              END)                                                   AS sla_20_pct,
  100.0 * AVG(CASE
                WHEN disposition='ANSWERED' AND connect_ts IS NOT NULL
                 AND TIMESTAMPDIFF(SECOND, enter_ts, connect_ts) <= 30 THEN 1
                ELSE 0
              END)                                                   AS sla_30_pct
FROM callstats.queue_calls
WHERE enter_ts >= NOW() - INTERVAL 2 DAY
GROUP BY DATE(enter_ts), queuename;
