# Roadmap

Что можно добавить в следующих итерациях. Приоритеты — по запросу заказчика отчёта ОКК.

## Приоритет 1 — «Переадресован»

**Метрика:** сколько звонков было переадресовано оператором.

**Где данные:** `asteriskcdrdb.cdr`, поля `dstchannel`, `lastapp='Transfer'`, `dcontext`. По `uniqueid` или `linkedid` можно соединить с `queue_log`.

**Что делать:**

1. Расширить `01_schema.sql`:

   ```sql
   ALTER TABLE queue_calls
     ADD COLUMN IF NOT EXISTS transferred TINYINT(1) NOT NULL DEFAULT 0,
     ADD COLUMN IF NOT EXISTS transferred_to VARCHAR(64) NULL;
   ```

2. В `callstats_rebuild_2d.sql` добавить пре-запрос из `cdr` для окна 48 часов:

   ```sql
   -- Собираем список звонков с переводами
   CREATE TEMPORARY TABLE tmp_transfers AS
   SELECT uniqueid, dstchannel
   FROM asteriskcdrdb.cdr
   WHERE calldate >= NOW() - INTERVAL 2 DAY
     AND lastapp IN ('Transfer', 'AttendedTransfer');
   ```

3. После INSERT в `queue_calls` — обновить флаг:

   ```sql
   UPDATE queue_calls qc
   JOIN tmp_transfers t ON t.uniqueid = qc.callid
   SET qc.transferred = 1,
       qc.transferred_to = SUBSTRING_INDEX(t.dstchannel, '/', -1)
   WHERE qc.enter_ts >= NOW() - INTERVAL 2 DAY;
   ```

4. В дашбордах добавить колонку "Переадресован":

   ```sql
   SUM(transferred) AS `Переадресован`
   ```

**Оценка:** ~2 часа. Основная проблема — сопоставить `queue_log.callid` с `cdr.uniqueid`. На разных FreePBX это может быть один и тот же ID, а может отличаться (если стоит `linkedid`-based CDR).

## Приоритет 2 — «Максимальное количество абонентов в очереди»

**Метрика:** пик одновременно ожидающих звонков за период.

**Где данные:** нигде — Asterisk не пишет snapshot состояния очереди в лог. Только текущее состояние доступно через `queue show` или AMI.

**Что делать:**

1. Новая таблица:

   ```sql
   CREATE TABLE callstats.queue_snapshot (
     ts        DATETIME NOT NULL,
     queuename VARCHAR(64) NOT NULL,
     waiting   INT NOT NULL,
     talking   INT NOT NULL,
     agents_online INT NOT NULL,
     PRIMARY KEY (ts, queuename)
   );
   ```

2. Скрипт `/usr/local/bin/queue_snapshot.sh`, cron `* * * * *` (раз в минуту):

   ```bash
   #!/bin/bash
   asterisk -rx "queue show" | \
     awk '/^[0-9]+ has/ { queue=$1 }
          /Callers/     { print queue"|"$2 }' | \
     mysql -u callstats_writer -p"$CALLSTATS_DB_PASS" callstats \
       -e "INSERT INTO queue_snapshot ..."
   ```

3. В дашборд «Нагрузка» добавить панель:

   ```sql
   SELECT queuename, MAX(waiting) AS `Макс. ожидающих`
   FROM queue_snapshot
   WHERE $__timeFilter(ts) AND queuename LIKE '${queue:raw}'
   GROUP BY queuename ORDER BY `Макс. ожидающих` DESC
   ```

**Оценка:** ~2 часа + сутки на накопление истории. Помни, что раз в минуту при большом кол-ве очередей даст ~1440 × N строк в день — предусмотреть ротацию (`WHERE ts < NOW() - INTERVAL 90 DAY DELETE`).

## Приоритет 3 — «Время простоя оператора»

**Метрика:** время, когда оператор в статусе `available` (принят в очередь и не в разговоре и не на паузе).

**Где данные:** `queue_log` пишет события `AGENTLOGIN`, `AGENTLOGOFF`, `PAUSE`, `UNPAUSE`.

**Что делать:**

1. Новая таблица периодов:

   ```sql
   CREATE TABLE callstats.agent_periods (
     agent       VARCHAR(128) NOT NULL,
     queuename   VARCHAR(64) NOT NULL,
     start_ts    DATETIME NOT NULL,
     end_ts      DATETIME NULL,
     state       ENUM('online','paused','talking','offline') NOT NULL,
     PRIMARY KEY (agent, queuename, start_ts)
   );
   ```

2. Скрипт-построитель, работающий на окне 48 часов:

   ```
   для каждого агента:
     собрать все события AGENTLOGIN/AGENTLOGOFF/PAUSE/UNPAUSE/CONNECT/COMPLETE*
     отсортировать по времени
     построить последовательные интервалы с state
   ```

3. Итоговые суммы для дашборда:

   ```sql
   SELECT agent,
     SUM(CASE WHEN state='online'
              THEN TIMESTAMPDIFF(SECOND, start_ts, IFNULL(end_ts, NOW()))
              ELSE 0 END) AS idle_sec,
     SUM(CASE WHEN state='paused'
              THEN TIMESTAMPDIFF(SECOND, start_ts, IFNULL(end_ts, NOW()))
              ELSE 0 END) AS paused_sec,
     SUM(CASE WHEN state='talking'
              THEN TIMESTAMPDIFF(SECOND, start_ts, IFNULL(end_ts, NOW()))
              ELSE 0 END) AS talking_sec
   FROM agent_periods
   WHERE $__timeFilter(start_ts)
   GROUP BY agent
   ```

**Оценка:** ~4 часа. Самая сложная часть — корректно строить интервалы, учитывая, что один агент может быть в нескольких очередях одновременно, и события каждой очереди приходят независимо.

## Приоритет 4 — Wrapup time

Время после окончания разговора, когда оператор ещё в статусе "постобработка" и не принимает новые звонки. Настраивается в очередях Asterisk (`wrapuptime`).

**Данные:** появляются в `queue_log` только если wrapuptime настроен. Проверить:

```sql
SELECT DISTINCT event FROM asteriskcdrdb.queue_log
WHERE time >= NOW() - INTERVAL 1 DAY;
```

Ищем `RINGNOANSWER` и переходы в готовность после `COMPLETECALLER`. Если события есть — реализуется аналогично простою.

## Приоритет 5 — Расширенная аналитика по клиентам

Добавить в `queue_calls` поле `caller_id` из `queue_log` и позволить фильтровать/группировать по номеру абонента. Полезно для:

- топ повторных звонящих;
- звонки от VIP-клиентов;
- географическое распределение (по префиксу).

**Оценка:** ~1 час.

## Долгоживущая история (год+)

При большом окне запросов и растущей `queue_calls` начнёт тормозить heatmap и таблица операторов. Тогда стоит:

1. Ввести таблицу `queue_hourly` с почасовыми агрегатами (аналог `queue_daily` только помельче).
2. Партиционировать `queue_calls` по месяцам.
3. Настроить архивацию: строки старше 6 месяцев → в отдельную БД/S3, из основной удалять.

## Мониторинг ETL в Grafana

Отдельный маленький дашборд, показывающий:

- время последнего успешного прогона `callstats_update.sh`;
- количество строк, добавленных за прогон;
- лаг между `NOW()` и `MAX(enter_ts)` в `queue_calls`.

Плюс алерт в Telegram/mail, если лаг > 15 минут.
