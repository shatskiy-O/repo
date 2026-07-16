# Zabbix HA-кластер «Terem Zabbix» — полное описание 

> Отказоустойчивый Zabbix: реплицируемая БД (Patroni + etcd), native HA сервера, плавающий VIP, дублированный веб-интерфейс, взаимный мониторинг узлов и внешний heartbeat в Telegram.
> **Собран:** 2026-07-16.

---

## 1. Обзор архитектуры

```
                     ┌──────────── VIP 172.19.0.24 (keepalived, VRID 231) ────────────┐
                     │   HAProxy :5000  →  всегда указывает на текущего Patroni-лидера  │
                     └─────────────────────────────────────────────────────────────────┘
                                 ▲                                        ▲
          ┌──────────────────────┴───────────┐        ┌───────────────────┴──────────────┐
          │ node1  «Zabbix-server» 172.19.0.38│        │ node2  «zabbix-2»   172.19.0.37   │
          │  etcd 3.5.15                       │        │  etcd 3.5.15                       │
          │  Patroni + PostgreSQL 15 (Leader)  │        │  Patroni + PostgreSQL 15 (Replica) │
          │  HAProxy :5000 + keepalived MASTER │        │  HAProxy :5000 + keepalived BACKUP │
          │  zabbix-server 7.4.12 (active)     │        │  zabbix-server 7.4.12 (standby)    │
          │  nginx :8080 + php-fpm (frontend)  │        │  nginx :8080 + php-fpm (frontend)  │
          │  zabbix-agent2                     │        │  zabbix-agent2                     │
          └────────────────────────────────────┘        └────────────────────────────────────┘
                                 │                                        │
                                 └───────────────── etcd-кворум (2 из 3) ─┘
                                                    │
                                     ┌──────────────┴───────────────┐
                                     │ node3 «passwork» 10.0.1.60    │
                                     │  etcd 3.5.16 (свидетель)      │
                                     │  watchdog → Telegram (proxy)  │
                                     └───────────────────────────────┘

               Алерты о проблемах ──► Zabbix action ──► Telegram (через SOCKS-прокси Литва)
               Отказ всего кластера ─► watchdog (node3) ─► Telegram (тот же прокси)
```

**Логика отказоустойчивости по слоям:**
1. **БД** — Patroni управляет PostgreSQL, потоковая репликация primary→replica. Кто primary, решает выбор через кворум etcd (переживает потерю 1 из 3 узлов). Автопереключение < 30 сек.
2. **Доступ к БД** — HAProxy на каждой ноде проверяет Patroni REST и направляет на текущего лидера; keepalived держит VIP `172.19.0.24` на живом узле. Клиенты всегда идут на `172.19.0.24:5000`.
3. **Сервер Zabbix** — native HA 7.4: оба демона на общей БД, один active, второй standby, failover по «last access».
4. **Веб** — nginx+php на обоих узлах; доступ через VIP → открывается на живом узле.
5. **Оповещения** — обычные проблемы шлёт активный сервер в Telegram; узлы мониторят друг друга; полный отказ ловит внешний watchdog на node3.

---

## 2. Узлы и адреса

| Узел | Hostname | IP | ОС / ядро | Роли |
|------|----------|-----|-----------|------|
| **node1** | Zabbix-server | 172.19.0.38 | Debian 12 (6.1) | etcd, Patroni (PG primary), HAProxy, keepalived **MASTER**, zabbix-server **active**, frontend, agent2 |
| **node2** | zabbix-2 | 172.19.0.37 | Debian 12 (6.1) | etcd, Patroni (PG replica), HAProxy, keepalived **BACKUP**, zabbix-server **standby**, frontend, agent2 |
| **node3** | passwork | 10.0.1.60 | Debian 11 (5.10) | etcd (только кворум-свидетель), watchdog-скрипт. Отдельная подсеть/хост — независимый домен отказа |
| **VIP** | — | 172.19.0.24 | — | плавающий адрес БД (keepalived → HAProxy :5000) |
| Прокси (Telegram) | Литва | <SOCKS_PROXY_HOST:PORT> | — | SOCKS5 для доставки алертов (внешний, вне кластера) |

---

## 3. Версии ПО

| Компонент | Версия | Установка |
|-----------|--------|-----------|
| Zabbix (server/frontend/agent2/web-service) | 7.4.12 | пакеты репозитория Zabbix |
| PostgreSQL | 15.18 (Debian) | пакет postgresql-15 |
| Patroni | 3.0.2 | пакет patroni |
| etcd | 3.5.15 (node1,2) / 3.5.16 (node3) | статический бинарь `/usr/local/bin/etcd` |
| HAProxy | 2.6.12 | пакет haproxy |
| keepalived | 2.2.7 | пакет keepalived |
| nginx | 1.22.1 | пакет nginx |
| php-fpm | 8.2 | пакет php8.2-fpm |

> etcd 3.5.15 и 3.5.16 совместимы (один minor 3.5.x). Zabbix на обоих узлах строго одной версии — требование native HA.

---

## 4. Сервисы и порты

| Сервис | Узлы | Порт | Назначение |
|--------|------|------|-----------|
| etcd | node1, node2, node3 | 2379 (client), 2380 (peer) | DCS-кворум для Patroni |
| PostgreSQL (Patroni) | node1, node2 | 5432 | БД `zabbix` (primary/replica) |
| Patroni REST API | node1, node2 | 8008 | health-check лидера (`/primary` → 200 только у primary) |
| HAProxy | node1, node2 | 5000 | вход в БД → маршрут на лидера |
| keepalived | node1, node2 | VRRP, VRID 231 | плавающий VIP 172.19.0.24 |
| zabbix-server | node1, node2 | 10051 | сервер мониторинга (HA) |
| nginx (frontend) | node1, node2 | 8080 | веб-интерфейс |
| php-fpm | node1, node2 | сокет `/run/php/zabbix.sock` | PHP-бэкенд веб |
| zabbix-agent2 | node1, node2 | 10050 | мониторинг самих нод |

**Веб-интерфейс:** основной адрес `http://172.19.0.24:8080` (через VIP — всегда живой узел). Прямые: `http://172.19.0.38:8080`, `http://172.19.0.37:8080`.

---

## 5. Учётные данные

| Что | Логин | Пароль |
|-----|-------|--------|
| БД Zabbix | `zabbix` | `<DB_PASSWORD>` |
| PostgreSQL суперпользователь | `postgres` | `<DB_PASSWORD>` |
| Репликация Patroni | `replicator` | `<REPL_PASSWORD>` |
| keepalived VRRP | — | `<VRRP_PASSWORD>` (auth_pass) |
| Telegram-бот (Zabbix-оповещения) | bot `<BOT_ID>` | канал `<TELEGRAM_CHAT_ID>` («ВЦ Теремъ - Оповещения Zabbix») |

> ⚠️ **Все секреты в этом документе заменены плейсхолдерами** (`<DB_PASSWORD>`, `<REPL_PASSWORD>`, `<VRRP_PASSWORD>`, `<TELEGRAM_BOT_TOKEN>`, `<TELEGRAM_CHAT_ID>`, `<BOT_ID>`, `<SOCKS_PROXY_HOST:PORT>`). Реальные значения — в защищённом хранилище (менеджер паролей / приватный раздел). При заполнении конфигов подставлять оттуда.

---

## 6. Конфигурации (полные тексты)

### 6.1 etcd

**node1 и node2** — запускаются через systemd-unit `/etc/systemd/system/etcd.service` с флагами (пример node1; на node2 поменять `--name` и адреса на `172.19.0.37`):
```ini
[Unit]
Description=etcd key-value store
After=network.target
[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \
  --name node1 \
  --data-dir /var/lib/etcd \
  --listen-client-urls http://0.0.0.0:2379 \
  --advertise-client-urls http://172.19.0.38:2379 \
  --listen-peer-urls http://0.0.0.0:2380 \
  --initial-advertise-peer-urls http://172.19.0.38:2380 \
  --initial-cluster node1=http://172.19.0.38:2380,node2=http://172.19.0.37:2380,node3=http://10.0.1.60:2380 \
  --initial-cluster-state new \
  --initial-cluster-token zabbix-cluster
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
```

**node3 (passwork)** — конфиг в `/etc/default/etcd`, unit `/etc/systemd/system/etcd.service` (ExecStart=/usr/local/bin/etcd):
```ini
ETCD_NAME="node3"
ETCD_LISTEN_PEER_URLS="http://10.0.1.60:2380"
ETCD_LISTEN_CLIENT_URLS="http://10.0.1.60:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.0.1.60:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.0.1.60:2379"
ETCD_INITIAL_CLUSTER="node1=http://172.19.0.38:2380,node2=http://172.19.0.37:2380,node3=http://10.0.1.60:2380"
ETCD_INITIAL_CLUSTER_TOKEN="zabbix-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_ENABLE_V2="false"
ETCD_DATA_DIR="/var/lib/etcd"
```

### 6.2 Patroni — `/etc/patroni/patroni.yml`

Пример **node1** (для node2: `name: node2`, адреса в `restapi` и `postgresql.connect_address` → `172.19.0.37`):
```yaml
scope: zabbix-cluster
namespace: /service/
name: node1

restapi:
  listen: 172.19.0.38:8008
  connect_address: 172.19.0.38:8008

etcd3:
  hosts:
    - 172.19.0.38:2379
    - 172.19.0.37:2379
    - 10.0.1.60:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 300
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all all peer
    - host all all 127.0.0.1/32 md5
    - host all all 172.19.0.0/24 md5
    - host all all 10.0.1.0/24 md5
    - host replication replicator 127.0.0.1/32 md5
    - host replication replicator 172.19.0.0/24 md5
    - host replication replicator 10.0.1.0/24 md5

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 172.19.0.38:5432
  data_dir: /var/lib/postgresql/15/main
  bin_dir: /usr/lib/postgresql/15/bin
  pgpass: /var/lib/postgresql/.pgpass
  authentication:
    replication:
      username: replicator
      password: <REPL_PASSWORD>
    superuser:
      username: postgres
      password: <DB_PASSWORD>
  parameters:
    unix_socket_directories: /var/run/postgresql

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```
systemd: `/etc/systemd/system/patroni.service` (User=postgres, ExecStart=/usr/bin/patroni /etc/patroni/patroni.yml).

### 6.3 HAProxy — `/etc/haproxy/haproxy.cfg` (одинаково на node1, node2)
```
global
    maxconn 1000
defaults
    log     global
    mode    tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s
listen postgres_write
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 172.19.0.38:5432 maxconn 500 check port 8008
    server node2 172.19.0.37:5432 maxconn 500 check port 8008
```

### 6.4 keepalived — `/etc/keepalived/keepalived.conf`

**node1** (MASTER; node2 — `state BACKUP`, `priority 100`):
```
global_defs {
    enable_script_security
    script_user root
}
vrrp_script chk_haproxy {
    script "/usr/bin/systemctl is-active --quiet haproxy"
    interval 2
    weight 2
    fall 2
    rise 2
}
vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 231
    priority 110
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass <VRRP_PASSWORD>
    }
    virtual_ipaddress {
        172.19.0.24/24
    }
    track_script {
        chk_haproxy
    }
}
```

### 6.5 Zabbix server — `/etc/zabbix/zabbix_server.conf` (ключевые строки)

**node1** (node2 — `HANodeName=node2`, `NodeAddress=172.19.0.37:10051`):
```ini
DBHost=172.19.0.24
DBPort=5000
DBName=zabbix
DBUser=zabbix
DBPassword=<DB_PASSWORD>
HANodeName=node1
NodeAddress=172.19.0.38:10051
```

### 6.6 Frontend — `/etc/zabbix/web/zabbix.conf.php` (на обоих узлах)
```php
$DB['TYPE']     = 'POSTGRESQL';
$DB['SERVER']   = '172.19.0.24';
$DB['PORT']     = '5000';
$DB['DATABASE'] = 'zabbix';
$DB['USER']     = 'zabbix';
$DB['PASSWORD'] = '<DB_PASSWORD>';
$DB['ENCRYPTION'] = true;
// $ZBX_SERVER не задан — фронтенд сам берёт адрес активного узла из БД
$ZBX_SERVER_NAME = 'Terem Zabbix';
```
nginx: `/etc/nginx/conf.d/zabbix.conf` — `listen 8080; server_name _; root /usr/share/zabbix/ui; fastcgi_pass unix:/var/run/php/zabbix.sock;`
php-fpm: `/etc/php/8.2/fpm/pool.d/zabbix.conf` — пул `[zabbix]`, `listen = /run/php/zabbix.sock`.

### 6.7 Zabbix agent2 — `/etc/zabbix/zabbix_agent2.conf` (на обоих узлах)
```ini
Server=127.0.0.1,172.19.0.38,172.19.0.37
ServerActive=127.0.0.1;172.19.0.38;172.19.0.37
Hostname=Zabbix server
```

---

## 7. Оповещения (алерты)

### 7.1 Как уходят обычные алерты
Активный узел Zabbix обрабатывает триггеры и отправляет уведомления через **action → Telegram**. Доставка идёт **через SOCKS-прокси в Литве** (`<SOCKS_PROXY_HOST:PORT>`), т.к. прямого доступа к `api.telegram.org` из сети нет. Канал: **«ВЦ Теремъ - Оповещения Zabbix»** (`<TELEGRAM_CHAT_ID>`, бот `<BOT_ID>`). При failover активным становится node2 — отправка продолжается автоматически.

### 7.2 Взаимный мониторинг узлов
Каждая нода мониторится как хост в Zabbix («Zabbix server - 1» / «Zabbix server - 2»), агенты разрешают опрос с обоих адресов (`Server=…,172.19.0.38,172.19.0.37`). Падение одного узла видит другой (active) → триггер «Zabbix agent not available» → алерт в Telegram. Дополнительно Zabbix HA пишет события «Cluster node [nodeX]: Status changed» при смене active/standby.

### 7.3 Внешний watchdog (полный отказ кластера)
На **node3 (passwork)** — независимый скрипт, cron каждую минуту. Проверяет оба узла на порт 10051; если молчат оба — шлёт 🔴 в Telegram через прокси; при восстановлении — ✅. Флаг `/tmp/zbx_cluster_down` защищает от спама.

`/usr/local/bin/zbx-cluster-watchdog.sh`:
```bash
#!/bin/bash
TOKEN="<TELEGRAM_BOT_TOKEN>"
CHAT="<TELEGRAM_CHAT_ID>"
STATE="/tmp/zbx_cluster_down"
API="https://api.telegram.org/bot$TOKEN/sendMessage"
PROXIES=(
    "socks5h://<SOCKS_PROXY_HOST:PORT>"
)
send() {
    local text="$1" px
    for px in "${PROXIES[@]}"; do
        if curl -x "$px" -s --max-time 10 --retry 3 --retry-delay 1 \
                "$API" --data-urlencode "chat_id=$CHAT" --data-urlencode "text=$text" \
                | grep -q '"ok":true'; then
            return 0
        fi
    done
    return 1
}
check() { timeout 3 bash -c "echo > /dev/tcp/$1/10051" 2>/dev/null; }
if check 172.19.0.38 || check 172.19.0.37; then
    if [ -f "$STATE" ]; then
        rm -f "$STATE"; send "✅ Zabbix-кластер снова доступен ($(date '+%F %T'))"
    fi
else
    if [ ! -f "$STATE" ]; then
        touch "$STATE"; send "🔴 ВЕСЬ Zabbix-кластер недоступен! node1 и node2 не отвечают на 10051. $(date '+%F %T')"
    fi
fi
```
cron: `* * * * * /usr/local/bin/zbx-cluster-watchdog.sh`

---

## 8. Шпаргалка проверки здоровья

```bash
# etcd (с любого узла)
etcdctl --endpoints=http://172.19.0.38:2379,http://172.19.0.37:2379,http://10.0.1.60:2379 endpoint health -w table
etcdctl --endpoints=http://172.19.0.38:2379 member list -w table

# Patroni / репликация
sudo patronictl -c /etc/patroni/patroni.yml list          # Leader + Replica, Lag ~0

# Zabbix native HA (на АКТИВНОМ узле)
sudo /usr/sbin/zabbix_server -R ha_status                 # active + standby

# VIP (только на одном узле)
ip a | grep 172.19.0.24

# БД через VIP
PGPASSWORD=<DB_PASSWORD> psql -h 172.19.0.24 -p 5000 -U zabbix -d zabbix -c "SELECT 1;"

# HAProxy слушает / keepalived без ошибок
sudo ss -tlnp | grep 5000
sudo journalctl -u keepalived --no-pager -n 15            # нет "invalid passwd"

# кто primary
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"     # f=primary, t=replica
```

---

## 9. Типовые операции

**Плановое переключение лидера БД:**
```bash
sudo patronictl -c /etc/patroni/patroni.yml switchover
```
**Задержка failover Zabbix (10с–15м, дефолт 60с):**
```bash
sudo /usr/sbin/zabbix_server -R ha_set_failover_delay=30s
```
**Бэкап БД (с активного лидера):**
```bash
sudo -u postgres pg_dump -Fc zabbix > /root/zabbix_$(date +%F).dump
sudo -u postgres pg_dumpall --globals-only > /root/pg_globals_$(date +%F).sql
```
**Обслуживание узла:** `switchover` (если это лидер) → остановить сервисы → работать → запустить; Patroni вернёт узел репликой автоматически.

---

## 10. Поведение при отказах

| Сценарий | Что происходит | Оповещение |
|----------|----------------|-----------|
| Падает node1 (лидер+active) | node2 → лидер БД, VIP на node2, zabbix node2 → active (через failover delay) | «node1 недоступен» в Telegram |
| Падает node2 (standby+replica) | node1 работает, кворум etcd жив | «node2 недоступен» |
| Возврат узла | входит репликой + standby; VIP по приоритету может вернуться на node1 | — |
| Падает node3 (свидетель) | БД/сервер работают (кворум node1+node2), резерва кворума нет — поднять node3 | взаимный мониторинг |
| Падает **весь** кластер | мониторинг стоит | watchdog node3 → 🔴 Telegram |

---

## 11. Диагностика частых проблем

- **etcd «cluster ID mismatch»** — разные `initial-cluster-token`/список членов. Один токен `zabbix-cluster`, одинаковый список из 3, чистый data-dir, старт близко по времени.
- **Очистка data-dir etcd не работает** — каталог `700 etcd:etcd`, маску раскрывает непривилегированный шелл. Чистить от root: `sudo rm -rf /var/lib/etcd && sudo mkdir … && chown etcd:etcd`.
- **keepalived «invalid passwd» + VIP на обоих** — разные `auth_pass` ИЛИ чужой VRRP с тем же `virtual_router_id` (конфликт виртуального MAC). Пароль одинаковый, VRID уникальный (231).
- **HAProxy не слушает 5000** — после правки конфига нужен `systemctl restart haproxy`.
- **Веб 502 / нет сокета** — нет php-fpm пула `/etc/php/8.2/fpm/pool.d/zabbix.conf`.
- **Patroni завис на «creating replica»** — прерванный pg_basebackup: stop Patroni → `pkill -u postgres` → очистить data_dir → start.
- **Zabbix «database error»** — проверить `DBHost=172.19.0.24` и `DBPort=5000` в zabbix_server.conf и zabbix.conf.php на обоих.
- **Watchdog молчит** — Telegram только через прокси; проверить `curl -x socks5h://<SOCKS_PROXY_HOST:PORT> …`; не удалять флаг `/tmp/zbx_cluster_down` между «падением» и «восстановлением».

