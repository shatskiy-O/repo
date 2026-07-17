# callstats-grafana

Call-center BI на базе Asterisk queue_log → MariaDB → Grafana.

Собирает аналитику по очередям FreePBX/Asterisk: KPI операторов, SLA, нагрузка по часам/дням/неделям, heatmap ожидания. Оптимизировано под руководительский отчёт (ежемесячная сводка ОКК).

## Архитектура

```
┌─────────────────────────────────────────────┐
│           АТС terem-pro (FreePBX)           │
│  ┌──────────────────────────────────────┐   │
│  │ asteriskcdrdb.queue_log (raw events) │   │
│  └──────────────────┬───────────────────┘   │
│                     │ каждые 5 мин          │
│                     ▼ (cron + shell + SQL)  │
│  ┌──────────────────────────────────────┐   │
│  │ callstats.queue_calls  (per call)    │   │
│  │ callstats.queue_daily  (aggregates)  │   │
│  └──────────────────┬───────────────────┘   │
└─────────────────────┼───────────────────────┘
                      │ SSH tunnel (autossh + systemd)
                      ▼ 127.0.0.1:3307 → ATS:3306
┌─────────────────────────────────────────────┐
│         VM passwork (Grafana host)          │
│  ┌──────────────────────────────────────┐   │
│  │ Grafana 12.3.2 (Docker)              │   │
│  │  ├─ Datasource: Callstats-MySQL      │   │
│  │  └─ 3 dashboards                     │   │
│  │     ├─ Колл-центр — Нагрузка         │   │
│  │     ├─ Колл-центр — Очереди          │   │
│  │     └─ Колл-центр — Оператор         │   │
│  └──────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

## Структура репозитория

```
callstats-grafana/
├── docs/                         # Документация
│   ├── ARCHITECTURE.md           # Как всё устроено, потоки данных
│   ├── DEPLOY.md                 # Полная инструкция развёртывания с нуля
│   ├── OPERATIONS.md             # Эксплуатация, откат, бэкапы
│   ├── TROUBLESHOOTING.md        # Разбор проблем и известных особенностей
│   ├── SQL_NOTES.md              # Особенности SQL под Grafana 12.x
│   └── ROADMAP.md                # Что можно доделать: переадресация, простой, snapshot
│
├── ats/                          # Всё, что живёт на АТС terem-pro
│   ├── sql/
│   │   ├── 01_schema.sql               # Создание callstats.*, юзеров, прав
│   │   ├── 02_migrate_disposition.sql  # Расширение queue_daily новыми колонками
│   │   └── callstats_rebuild_2d.sql    # ETL-скрипт (окно 48 ч)
│   ├── scripts/
│   │   └── callstats_update.sh   # Обёртка над SQL, запускается по cron
│   └── systemd/
│       └── ats-mysql-tunnel.service  # SSH-туннель для Grafana (со стороны АТС не нужен, файл в grafana/)
│
├── grafana/                      # Всё, что живёт на VM с Grafana
│   ├── compose/
│   │   └── docker-compose.yml    # Grafana в Docker + провижининг
│   ├── provisioning/
│   │   ├── datasources/
│   │   │   └── callstats.yaml    # Datasource Callstats-MySQL
│   │   └── dashboards/
│   │       └── callstats-provider.yaml
│   ├── dashboards/
│   │   ├── callstats-load.json      # Колл-центр — Нагрузка
│   │   ├── callstats-queues.json    # Колл-центр — Очереди
│   │   └── callstats-agent.json     # Колл-центр — Оператор
│   └── systemd/
│       └── ats-mysql-tunnel.service  # SSH-туннель к MySQL АТС
│
└── tools/                        # Утилиты
    ├── backup.sh                 # Создать golden-бэкап Grafana
    ├── restore.sh                # Откатить Grafana из бэкапа
    └── healthcheck.sh            # Проверка живости туннеля, ETL, данных
```

## Быстрый старт

Разворачивание с нуля — см. [docs/DEPLOY.md](docs/DEPLOY.md).

Обновление уже развёрнутой инсталляции:

```bash
# на VM с Grafana
sudo tools/backup.sh
sudo cp -a grafana/dashboards/*.json /opt/grafana/dashboards/
sudo docker restart grafana
```

## Основные показатели

| Метрика | Источник | Дашборд |
|---|---|---|
| Получено / Отвечено / Неотвечено | `queue_calls` | Все три |
| Несостоявшийся | `queue_calls.disposition IN (ABANDON, EXITWITHTIMEOUT, EXITEMPTY)` | Все три |
| ASA (среднее ожидание) | `enter_ts → connect_ts` | Очереди, Нагрузка |
| AHT (среднее обслуживание) | `enter_ts → end_ts` | Оператор, Нагрузка |
| SLA 20 / 30 сек | `queue_daily.sla_20_pct`, `sla_30_pct` | Очереди, Оператор |
| Нагрузка по неделям/часам/дням недели | `queue_calls` | Нагрузка |
| Топ операторов | `queue_calls GROUP BY agent` | Очереди, Нагрузка |
| Heatmap ожидания | `queue_calls`, бакеты 15 мин × 5 сек | Очереди, Оператор |

Чего пока нет (см. [docs/ROADMAP.md](docs/ROADMAP.md)):

- Переадресация (нужен JOIN с CDR).
- Максимум абонентов в очереди в моменте (нужен snapshot состояния очереди).
- Время простоя оператора (нужен парсинг PAUSE / UNPAUSE / AGENTLOGIN / AGENTLOGOFF).

## Конфигурация

Все чувствительные значения (пароли БД, admin-пароль Grafana, IP-адреса, приватные ключи) вынесены в переменные окружения и отсутствуют в репозитории. См. [`.env.example`](.env.example) — скопируйте его в `.env` и заполните под свою инсталляцию.

## Требования

**АТС:**
- FreePBX / Asterisk с активными очередями (queue_log в MariaDB)
- MariaDB 10.x
- root-доступ к MariaDB (нужен для создания пользователей и прав)

**VM с Grafana:**
- Debian 11+ / Ubuntu 22.04+
- Docker + Docker Compose
- autossh (для устойчивого SSH-туннеля)
- Grafana 12.x (проверено на 12.3.2)

## Лицензия

Внутренний проект. Публикация под лицензией — на усмотрение владельца репозитория.
