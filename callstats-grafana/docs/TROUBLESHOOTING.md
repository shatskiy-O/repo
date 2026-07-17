# Разбор проблем

Все проблемы, с которыми я столкнулся в процессе, и их решения. Экономит время следующим.

## Grafana

### Панель показывает «Нет данных», а SQL руками возвращает строки

**Симптом:** в Grafana 12.x панель `timeseries` пуста. Тот же `rawSql`, выполненный через `curl … /api/ds/query`, возвращает `status: 500` c ошибкой:

```
converting time columns failed: failed to convert time column: unable to convert data to a time field
```

**Причина:** Grafana 12.x требует, чтобы столбец `time` был типа `DATETIME`. `CONCAT(day, ' 00:00:00')` в MariaDB возвращает `VARCHAR`.

**Решение:** обернуть в `CAST`:

```sql
SELECT CAST(CONCAT(day,' 00:00:00') AS DATETIME) AS time, ...
```

### Heatmap падает с TypeError: undefined is not an object (evaluating 'o.config')

**Причина:** пустые `options.color: {}` и `fieldConfig.defaults: {}` в панели `heatmap`. В 12.x рендерер лезет в `color.mode/scheme/steps` без проверки на null.

**Решение:** заполнить `options` корректными значениями (см. `heatmap_panel()` в `tools/build_dashboards.py`):

```python
"color": {
    "mode": "scheme", "scheme": "Oranges", "fill": "dark-orange",
    "exponent": 0.5, "steps": 64, ...
}
```

### Heatmap отображается, но ось Y идёт вразнобой: w_15, w_1635, w_5

**Причина:** `metric`-строки сортируются лексикографически. `'1635' < '15' < '5'` — как строки, а не числа.

**Решение:** LPAD с ведущими нулями до одинаковой ширины:

```sql
LPAD(FLOOR(TIMESTAMPDIFF(SECOND, enter_ts, connect_ts)/5)*5, 5, '0')
```

Даёт метки вида `00000`, `00005`, `00010`, ..., `00120`.

### Верхняя корзина в heatmap показывается как «0120+»

**Причина:** `LPAD('120+', 5, '0')` → `'0120+'` (лидирующие нули для строки, чтобы вписаться в 5 символов).

**Решение:** для верхнего бакета использовать явный маркер `'>120'`. Символ `>` (ASCII 62) сортируется после цифр (ASCII 48–57), поэтому строка `'>120'` окажется в самом верху оси Y.

### Русский интерфейс не включается через `GF_DEFAULT_LANGUAGE`

**Симптом:** в docker-compose `GF_DEFAULT_LANGUAGE=ru-RU`, `/api/frontend/settings` возвращает `defaultLocale: null`, интерфейс на английском.

**Причина:** в Grafana 12.x язык — per-user настройка. Env-переменная работает только если и org, и user preferences пустые.

**Решение:** прописать язык явно через API:

```bash
curl -sS -u admin:PASS -X PUT http://127.0.0.1:3000/api/org/preferences \
  -H 'Content-Type: application/json' \
  -d '{"language":"ru-RU","weekStart":"monday","theme":""}'

curl -sS -u admin:PASS -X PUT http://127.0.0.1:3000/api/user/preferences \
  -H 'Content-Type: application/json' \
  -d '{"language":"ru-RU","weekStart":"monday","theme":""}'
```

В браузере: Ctrl+F5.

### Фильтр `${queue:sqlstring}` не работает

**Симптом:** при выборе конкретной очереди дашборд отдаёт "No data", хотя при `All` работает.

**Причина:** формат `sqlstring` оборачивает значение в кавычки *внутри* значения — Grafana подставляет `'605'` вместо `605`, а SQL уже добавляет свои кавычки, получается `'\'605\''`.

**Решение:** использовать `${queue:raw}` внутри уже квотированного места:

```sql
WHERE queuename LIKE '${queue:raw}'
```

и в переменной `allValue: "%"` — тогда «Все» отправляет `%`, а конкретная очередь — своё значение без лишних кавычек.

## MariaDB на АТС

### `ERROR 1142: ALTER command denied to user 'callstats_writer'`

**Причина:** при первичной установке writer'у выдали только DML-права (SELECT/INSERT/UPDATE/DELETE), без DDL. При миграции нужен ALTER.

**Решение:** от root MariaDB:

```sql
GRANT ALTER, INDEX, CREATE, DROP, REFERENCES ON callstats.*
  TO 'callstats_writer'@'localhost';
FLUSH PRIVILEGES;
```

Схема в `01_schema.sql` уже выдаёт весь этот набор.

### `sudo mysql callstats` возвращает Access denied for 'root'@'localhost' (using password: NO)

**Причина:** на FreePBX socket-auth для root MariaDB не включён (unix_socket plugin отсутствует).

**Решение:** использовать пароль root MariaDB. На FreePBX его нет в `freepbx.conf` — только там `freepbxuser`, у которого нет прав на `callstats`. Пароль root придётся достать из `/root/.my.cnf` или установочных заметок.

### ETL пишет UNKNOWN у многих звонков

**Причина:** это не ошибка, а особенность окна 48 часов. Звонок, который начался, но ещё не завершился к моменту прогона ETL, будет UNKNOWN. При следующем прогоне через 5 минут, если появилось завершающее событие, звонок переклассифицируется в ANSWERED/ABANDON/…

Если UNKNOWN висят и через день — значит в `queue_log` реально нет финальных событий. Проверить:

```sql
SELECT event, COUNT(*) FROM asteriskcdrdb.queue_log
WHERE callid = 'PROBLEMATIC_CALLID' GROUP BY event;
```

## SSH-туннель

### `ss -lntp | grep 3307` ничего не показывает

**Диагностика:**

```bash
sudo systemctl status ats-mysql-tunnel.service --no-pager
sudo journalctl -u ats-mysql-tunnel.service -n 50 --no-pager
```

Частые причины:
- истёк или не подхватился SSH-ключ (проверить `/home/tor/.ssh/ats_grafana_rsa` chmod 600);
- на АТС в authorized_keys ключ прописан, но с restrict-опциями, ломающими port forwarding;
- на АТС в sshd_config `AllowTcpForwarding no`;
- unit-файл ссылается на несуществующий путь `/usr/lib/autossh/autossh` — на некоторых дистрибутивах бинарник в `/usr/bin/autossh`, проверь `which autossh`.

### Туннель поднимается, но mysql-клиент из VM выдаёт `ERROR 2003 (HY000): Can't connect to MySQL server on '127.0.0.1' (111)`

**Причина:** autossh стартовал раньше сети. Solution в unit-файле: `After=network-online.target Wants=network-online.target`.

Проверить, что unit был перечитан после правки:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ats-mysql-tunnel.service
```

### Туннель работает, но Grafana изнутри контейнера не видит порт 3307

**Причина:** внутри контейнера `localhost` — это сам контейнер, а не хост. `127.0.0.1:3307` на VM — недоступен из контейнера напрямую.

**Решение:** в datasource указан `host.docker.internal:3307`, а в docker-compose есть:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

Если по каким-то причинам не работает — как fallback можно использовать IP хоста в docker-сети:

```bash
docker network inspect bridge | grep Gateway
# обычно 172.17.0.1
```

И прописать `172.17.0.1:3307` в datasource.

## Провижининг

### Изменения в JSON не подхватываются Grafana

**Причина 1:** `updateIntervalSeconds` в provider-конфиге больше чем ждали. По умолчанию 30 секунд, но иногда обновление ленится. `sudo docker restart grafana` решает.

**Причина 2:** дашборд ранее был отредактирован в UI и сохранён — Grafana в этом случае поднимает `version`, а из файла подгружает только если `version` больше. Решение: увеличить `version` в JSON перед деплоем.

**Причина 3:** битый JSON. Проверять всегда:

```bash
jq . grafana/dashboards/callstats-load.json >/dev/null && echo OK
```

## Отладочные команды

**Одним запросом проверить датасорс:**

```bash
curl -sS -u admin:PASS \
  http://127.0.0.1:3000/api/datasources/uid/PC8CDFBD862B3D820 | jq
```

**Прогнать конкретный SQL через Grafana:**

```bash
curl -sS -u admin:PASS -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:3000/api/ds/query \
  -d @- <<'JSON' | jq '.results.A'
{
  "queries": [{
    "refId":"A",
    "datasource":{"type":"mysql","uid":"PC8CDFBD862B3D820"},
    "rawSql":"SELECT NOW() AS time, 1 AS v",
    "format":"time_series"
  }],
  "from":"now-1h","to":"now"
}
JSON
```

**Посмотреть, что в БД реально есть за последний час:**

```bash
mysql -h 127.0.0.1 -P 3307 --protocol=tcp -ucallstats_ro -p callstats <<'SQL'
SELECT NOW() AS now_srv,
       MAX(enter_ts) AS last_call,
       TIMESTAMPDIFF(SECOND, MAX(enter_ts), NOW()) AS sec_ago
FROM queue_calls;

SELECT disposition, COUNT(*)
FROM queue_calls
WHERE enter_ts >= NOW() - INTERVAL 1 HOUR
GROUP BY disposition;
SQL
```
