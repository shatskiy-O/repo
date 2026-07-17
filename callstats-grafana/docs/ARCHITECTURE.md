# Архитектура callstats-grafana

## Общая схема

```
┌────────────────────────────────────────────────────────┐
│                 АТС (FreePBX/Asterisk)                 │
│                                                        │
│   Asterisk queue_log ── пишется системой очередей ──►  │
│           │                                            │
│           │ каждые 5 мин (cron)                        │
│           ▼                                            │
│   /usr/local/bin/callstats_update.sh                   │
│           │                                            │
│           │ mysql < callstats_rebuild_2d.sql           │
│           ▼                                            │
│   callstats.queue_calls   (одна строка на звонок)      │
│   callstats.queue_daily   (агрегаты за сутки)          │
│                                                        │
│   MariaDB: 127.0.0.1:3306, доступ только с localhost   │
└─────────────────────────┬──────────────────────────────┘
                          │
                          │ SSH-туннель (autossh + systemd)
                          │ ключ: /home/tor/.ssh/ats_grafana_rsa
                          ▼
┌────────────────────────────────────────────────────────┐
│                    VM с Grafana                        │
│                                                        │
│   127.0.0.1:3307 (autossh keeps alive) ────────────►   │
│           │                                            │
│           ▼                                            │
│   Grafana 12.3.2 в Docker                              │
│    ├─ Datasource "Callstats-MySQL"                     │
│    │   host: host.docker.internal:3307                 │
│    │   user: callstats_ro (read-only)                  │
│    │                                                   │
│    └─ 3 дашборда (folder "Callstats")                  │
│        ├─ callstats-load   → Колл-центр — Нагрузка     │
│        ├─ callstats-queues → Колл-центр — Очереди      │
│        └─ callstats-agent  → Колл-центр — Оператор     │
│                                                        │
│   Веб: http://GF_HOST:3000                             │
└────────────────────────────────────────────────────────┘
```

## Компоненты

### 1. Источник данных — Asterisk queue_log

Asterisk сам пишет события очередей в `asteriskcdrdb.queue_log`. Форматы событий:

| Событие | Смысл |
|---|---|
| `ENTERQUEUE` | Звонящий встал в очередь |
| `CONNECT` | Соединение с оператором |
| `COMPLETEAGENT` | Оператор положил трубку |
| `COMPLETECALLER` | Клиент положил трубку |
| `ABANDON` | Клиент бросил трубку до соединения |
| `EXITWITHTIMEOUT` | Истёк таймаут очереди |
| `EXITEMPTY` | В очереди не было операторов |
| `EXITWITHKEY` | Клиент вышел по DTMF |

Мы этот лог не меняем, только читаем.

### 2. ETL — обогащение и агрегация

**Обёртка:** `/usr/local/bin/callstats_update.sh` — читает пароль writer'а из `/root/.callstats_db.conf` и вызывает mysql-клиент.

**SQL:** `/usr/local/bin/callstats_rebuild_2d.sql` — пересобирает окно последних 48 часов. Идемпотентный: удаляет своё окно и вставляет заново.

**Расписание:** cron `*/5 * * * *` в `/etc/cron.d/callstats_update`.

**Что делает SQL:**

1. Из `queue_log` группирует события по (`callid`, `queuename`) в одну строку `queue_calls`:
   - `enter_ts` = MIN(time WHERE event=ENTERQUEUE)
   - `connect_ts` = MIN(time WHERE event=CONNECT)
   - `end_ts` = MIN(time WHERE event ∈ финальные)
   - `agent` = agent из события CONNECT
   - `disposition` = приоритетно ANSWERED, иначе ABANDON, иначе EXITWITHTIMEOUT/EXITEMPTY/EXITWITHKEY

2. Строит дневные агрегаты в `queue_daily` по (`day`, `queuename`):
   - `offered/answered/abandoned/exit_timeout/exit_empty/not_completed`
   - `asa_sec` — среднее время до ответа
   - `sla_20_pct`, `sla_30_pct` — доля отвеченных за 20 и 30 секунд

### 3. Хранение — MariaDB на АТС

**База:** `callstats`
**Таблицы:**

- `queue_calls (callid, queuename, enter_ts, connect_ts, end_ts, agent, disposition)`
  Индексы по `enter_ts`, `(queuename, enter_ts)`, `(agent, enter_ts)`.
- `queue_daily (day, queuename, offered, answered, abandoned, exit_timeout, exit_empty, not_completed, asa_sec, sla_20_pct, sla_30_pct)`
  PK по `(day, queuename)`.

**Пользователи:**

- `callstats_writer@localhost` — ETL: SELECT/INSERT/UPDATE/DELETE + DDL на `callstats.*`, SELECT на `asteriskcdrdb.queue_log`.
- `callstats_ro@%` — только SELECT на `callstats.*`.

### 4. Транспорт — SSH-туннель

`ats-mysql-tunnel.service` (systemd на VM с Grafana) поднимает через `autossh`:

```
127.0.0.1:3307 (VM) ──► ATS:22 ──► 127.0.0.1:3306 (АТС)
```

Аутентификация — по SSH-ключу `/home/tor/.ssh/ats_grafana_rsa`. На АТС ключ прописан в `~grafana/.ssh/authorized_keys`.

Плюсы такого подхода:
- MariaDB на АТС не выставляется наружу;
- нет проблем с фаерволом (нужен только SSH-порт, обычно уже открытый);
- autossh автоматически восстанавливает падшую сессию.

### 5. Grafana в Docker

- Образ `grafana/grafana-oss:latest` (проверено на 12.3.2).
- Данные в `/opt/grafana/data`.
- Провижининг: `/opt/grafana/provisioning/{datasources,dashboards}`.
- JSON-дашборды: `/opt/grafana/dashboards` монтируется как `/etc/grafana/dashboards`.
- Русский язык через `GF_DEFAULT_LANGUAGE=ru-RU` + `/api/org/preferences {"language":"ru-RU"}`.

### 6. Datasource

- UID `PC8CDFBD862B3D820` (фиксирован).
- Host: `host.docker.internal:3307` (внутри Docker резолвится в хост-машину).
- User: `callstats_ro`.

## Потоки данных при отображении дашборда

1. Пользователь открывает дашборд «Колл-центр — Нагрузка» с фильтрами Очередь=Все, Оператор=Все.
2. Grafana для каждой панели рендерит SQL-запрос, подставляя `${queue:raw}` → `%`.
3. Запрос уходит через Docker в MySQL-плагин Grafana.
4. Плагин через `host.docker.internal:3307` попадает в autossh-туннель.
5. Туннель доносит запрос до MariaDB на АТС.
6. Ответ идёт обратно тем же путём.

Кэширования на стороне Grafana нет — при каждом refresh делается новый SQL-запрос.

## Ключевые решения и почему

**Почему не сохраняем сырые события в свою БД, а перестраиваем каждые 5 минут?**
Окно 48 часов, ~10k событий на день — перестроение занимает < 1 сек. Плюс — ETL идемпотентный: если сломался, следующий запуск всё починит.

**Почему SSH-туннель, а не открытый MySQL-порт?**
На АТС минимум attack surface. MySQL не выставлен наружу вообще.

**Почему UID datasource жёстко зашит?**
Все JSON-дашборды ссылаются на UID. Если UID сменится, дашборды разом сломаются. Фиксация UID даёт возможность переустановить Grafana с нуля и сохранить все дашборды.

**Почему schemaVersion=41?**
Grafana 12.3.2 требует именно эту схему. При понижении версии Grafana schemaVersion можно опустить, но лучше не смешивать.

**Почему CAST(CONCAT(day, ...) AS DATETIME)?**
Grafana 12.x строже проверяет тип поля `time`. `CONCAT` в MariaDB возвращает VARCHAR, что приводит к ошибке `converting time columns failed`. Явный CAST решает проблему.
