# Zabbix HA Cluster "Terem Zabbix" — Full Description

A fault-tolerant Zabbix setup: replicated database (Patroni + etcd), native server HA, a floating VIP, a duplicated web interface, mutual node monitoring, and an external heartbeat to Telegram. Built: 2026-07-16.

## 1. Architecture Overview

```
                     ┌──────────── VIP 172.19.0.24 (keepalived, VRID 231) ────────────┐
                     │   HAProxy :5000  →  always points to the current Patroni leader  │
                     └─────────────────────────────────────────────────────────────────┘
                                 ▲                                        ▲
          ┌──────────────────────┴───────────┐        ┌───────────────────┴──────────────┐
          │ node1  "Zabbix-server" 172.19.0.38│        │ node2  "zabbix-2"   172.19.0.37   │
          │  etcd 3.5.15                       │        │  etcd 3.5.15                       │
          │  Patroni + PostgreSQL 15 (Leader)  │        │  Patroni + PostgreSQL 15 (Replica) │
          │  HAProxy :5000 + keepalived MASTER │        │  HAProxy :5000 + keepalived BACKUP │
          │  zabbix-server 7.4.12 (active)     │        │  zabbix-server 7.4.12 (standby)    │
          │  nginx :8080 + php-fpm (frontend)  │        │  nginx :8080 + php-fpm (frontend)  │
          │  zabbix-agent2                     │        │  zabbix-agent2                     │
          └────────────────────────────────────┘        └────────────────────────────────────┘
                                 │                                        │
                                 └───────────────── etcd quorum (2 of 3) ─┘
                                                    │
                                     ┌──────────────┴───────────────┐
                                     │ node3 "passwork" 10.0.1.60    │
                                     │  etcd 3.5.16 (witness)        │
                                     │  watchdog → Telegram (proxy)  │
                                     └───────────────────────────────┘
               Problem alerts ──────► Zabbix action ──► Telegram (via SOCKS proxy, Lithuania)
               Whole-cluster outage ► watchdog (node3) ─► Telegram (same proxy)
```

Fault tolerance, layer by layer:

- **Database** — Patroni manages PostgreSQL with streaming replication primary→replica. Which node is primary is decided by an election through the etcd quorum (survives the loss of 1 of 3 nodes). Automatic switchover < 30 s.
- **Database access** — HAProxy on each node checks the Patroni REST API and routes to the current leader; keepalived keeps the VIP 172.19.0.24 on a live node. Clients always connect to 172.19.0.24:5000.
- **Zabbix server** — native HA 7.4: both daemons share a common DB, one is active, the other standby, failover by "last access".
- **Web** — nginx+php on both nodes; access via the VIP → served by the live node.
- **Alerting** — normal problems are sent by the active server to Telegram; the nodes monitor each other; a total outage is caught by the external watchdog on node3.

## 2. Nodes and Addresses

| Node | Hostname | IP | OS / Kernel | Roles |
|------|----------|-----|-------------|-------|
| node1 | Zabbix-server | 172.19.0.38 | Debian 12 (6.1) | etcd, Patroni (PG primary), HAProxy, keepalived MASTER, zabbix-server active, frontend, agent2 |
| node2 | zabbix-2 | 172.19.0.37 | Debian 12 (6.1) | etcd, Patroni (PG replica), HAProxy, keepalived BACKUP, zabbix-server standby, frontend, agent2 |
| node3 | passwork | 10.0.1.60 | Debian 11 (5.10) | etcd (quorum witness only), watchdog script. Separate subnet/host — an independent failure domain |
| VIP | — | 172.19.0.24 | — | floating DB address (keepalived → HAProxy :5000) |
| Proxy (Telegram) | Lithuania | `<SOCKS_PROXY_HOST:PORT>` | — | SOCKS5 for alert delivery (external, outside the cluster) |

## 3. Software Versions

| Component | Version | Installation |
|-----------|---------|--------------|
| Zabbix (server/frontend/agent2/web-service) | 7.4.12 | Zabbix repository packages |
| PostgreSQL | 15.18 (Debian) | `postgresql-15` package |
| Patroni | 3.0.2 | `patroni` package |
| etcd | 3.5.15 (node1,2) / 3.5.16 (node3) | static binary `/usr/local/bin/etcd` |
| HAProxy | 2.6.12 | `haproxy` package |
| keepalived | 2.2.7 | `keepalived` package |
| nginx | 1.22.1 | `nginx` package |
| php-fpm | 8.2 | `php8.2-fpm` package |

etcd 3.5.15 and 3.5.16 are compatible (same minor 3.5.x). Zabbix must be exactly the same version on both nodes — a native HA requirement.

## 4. Services and Ports

| Service | Nodes | Port | Purpose |
|---------|-------|------|---------|
| etcd | node1, node2, node3 | 2379 (client), 2380 (peer) | DCS quorum for Patroni |
| PostgreSQL (Patroni) | node1, node2 | 5432 | zabbix DB (primary/replica) |
| Patroni REST API | node1, node2 | 8008 | leader health check (`/primary` → 200 only on primary) |
| HAProxy | node1, node2 | 5000 | DB entry point → route to leader |
| keepalived | node1, node2 | VRRP, VRID 231 | floating VIP 172.19.0.24 |
| zabbix-server | node1, node2 | 10051 | monitoring server (HA) |
| nginx (frontend) | node1, node2 | 8080 | web interface |
| php-fpm | node1, node2 | socket `/run/php/zabbix.sock` | PHP web backend |
| zabbix-agent2 | node1, node2 | 10050 | monitoring of the nodes themselves |

Web interface: primary address http://172.19.0.24:8080 (via the VIP — always a live node). Direct: http://172.19.0.38:8080, http://172.19.0.37:8080.

## 5. Credentials

| Item | Login | Password |
|------|-------|----------|
| Zabbix DB | zabbix | `<DB_PASSWORD>` |
| PostgreSQL superuser | postgres | `<DB_PASSWORD>` |
| Patroni replication | replicator | `<REPL_PASSWORD>` |
| keepalived VRRP | — | `<VRRP_PASSWORD>` (auth_pass) |
| Telegram bot (Zabbix alerts) | bot `<BOT_ID>` | channel `<TELEGRAM_CHAT_ID>` ("ВЦ Теремъ - Оповещения Zabbix") |

> ⚠️ All secrets in this document are replaced with placeholders (`<DB_PASSWORD>`, `<REPL_PASSWORD>`, `<VRRP_PASSWORD>`, `<TELEGRAM_BOT_TOKEN>`, `<TELEGRAM_CHAT_ID>`, `<BOT_ID>`, `<SOCKS_PROXY_HOST:PORT>`). Real values live in secure storage (password manager / private section). Substitute them from there when filling in configs.

## 6. Configurations (Full Texts)

### 6.1 etcd

node1 and node2 — started via the systemd unit `/etc/systemd/system/etcd.service` with flags (example for node1; on node2 change `--name` and the addresses to 172.19.0.37):

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

node3 (passwork) — config in `/etc/default/etcd`, unit `/etc/systemd/system/etcd.service` (`ExecStart=/usr/local/bin/etcd`):

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

Example for node1 (for node2: `name: node2`, addresses in `restapi` and `postgresql.connect_address` → 172.19.0.37):

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

systemd: `/etc/systemd/system/patroni.service` (`User=postgres`, `ExecStart=/usr/bin/patroni /etc/patroni/patroni.yml`).

### 6.3 HAProxy — `/etc/haproxy/haproxy.cfg` (identical on node1, node2)

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

node1 (MASTER; node2 — `state BACKUP`, `priority 100`):

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

### 6.5 Zabbix server — `/etc/zabbix/zabbix_server.conf` (key lines)

node1 (node2 — `HANodeName=node2`, `NodeAddress=172.19.0.37:10051`):

```
DBHost=172.19.0.24
DBPort=5000
DBName=zabbix
DBUser=zabbix
DBPassword=<DB_PASSWORD>
HANodeName=node1
NodeAddress=172.19.0.38:10051
```

### 6.6 Frontend — `/etc/zabbix/web/zabbix.conf.php` (on both nodes)

```php
$DB['TYPE']     = 'POSTGRESQL';
$DB['SERVER']   = '172.19.0.24';
$DB['PORT']     = '5000';
$DB['DATABASE'] = 'zabbix';
$DB['USER']     = 'zabbix';
$DB['PASSWORD'] = '<DB_PASSWORD>';
$DB['ENCRYPTION'] = true;
// $ZBX_SERVER is not set — the frontend reads the active node's address from the DB itself
$ZBX_SERVER_NAME = 'Terem Zabbix';
```

nginx: `/etc/nginx/conf.d/zabbix.conf` — `listen 8080; server_name _; root /usr/share/zabbix/ui; fastcgi_pass unix:/var/run/php/zabbix.sock;`
php-fpm: `/etc/php/8.2/fpm/pool.d/zabbix.conf` — pool `[zabbix]`, `listen = /run/php/zabbix.sock`.

### 6.7 Zabbix agent2 — `/etc/zabbix/zabbix_agent2.conf` (on both nodes)

```
Server=127.0.0.1,172.19.0.38,172.19.0.37
ServerActive=127.0.0.1;172.19.0.38;172.19.0.37
Hostname=Zabbix server
```

## 7. Alerting

### 7.1 How normal alerts are delivered

The active Zabbix node processes triggers and sends notifications via an action → Telegram. Delivery goes through a SOCKS proxy in Lithuania (`<SOCKS_PROXY_HOST:PORT>`), because there is no direct access to api.telegram.org from the network. Channel: "ВЦ Теремъ - Оповещения Zabbix" (`<TELEGRAM_CHAT_ID>`, bot `<BOT_ID>`). On failover, node2 becomes active — sending continues automatically.

### 7.2 Mutual node monitoring

Each node is monitored as a host in Zabbix ("Zabbix server - 1" / "Zabbix server - 2"); the agents allow polling from both addresses (`Server=…,172.19.0.38,172.19.0.37`). If one node goes down, the other (active) sees it → trigger "Zabbix agent not available" → alert to Telegram. Additionally, Zabbix HA logs "Cluster node [nodeX]: Status changed" events when active/standby switches.

### 7.3 External watchdog (total cluster outage)

On node3 (passwork) — an independent script, cron every minute. It checks both nodes on port 10051; if both are silent, it sends 🔴 to Telegram via the proxy; on recovery — ✅. The flag `/tmp/zbx_cluster_down` guards against spam.

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
        rm -f "$STATE"; send "✅ Zabbix cluster is available again ($(date '+%F %T'))"
    fi
else
    if [ ! -f "$STATE" ]; then
        touch "$STATE"; send "🔴 The ENTIRE Zabbix cluster is down! node1 and node2 are not answering on 10051. $(date '+%F %T')"
    fi
fi
```

cron: `* * * * * /usr/local/bin/zbx-cluster-watchdog.sh`

## 8. Health-Check Cheat Sheet

```bash
# etcd (from any node)
etcdctl --endpoints=http://172.19.0.38:2379,http://172.19.0.37:2379,http://10.0.1.60:2379 endpoint health -w table
etcdctl --endpoints=http://172.19.0.38:2379 member list -w table

# Patroni / replication
sudo patronictl -c /etc/patroni/patroni.yml list          # Leader + Replica, Lag ~0

# Zabbix native HA (on the ACTIVE node)
sudo /usr/sbin/zabbix_server -R ha_status                 # active + standby

# VIP (should be on only one node)
ip a | grep 172.19.0.24

# DB via the VIP
PGPASSWORD=<DB_PASSWORD> psql -h 172.19.0.24 -p 5000 -U zabbix -d zabbix -c "SELECT 1;"

# HAProxy listening / keepalived without errors
sudo ss -tlnp | grep 5000
sudo journalctl -u keepalived --no-pager -n 15            # no "invalid passwd"

# who is primary
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"     # f=primary, t=replica
```

## 9. Common Operations

Planned DB leader switchover:

```bash
sudo patronictl -c /etc/patroni/patroni.yml switchover
```

Zabbix failover delay (10s–15m, default 60s):

```bash
sudo /usr/sbin/zabbix_server -R ha_set_failover_delay=30s
```

DB backup (from the active leader):

```bash
sudo -u postgres pg_dump -Fc zabbix > /root/zabbix_$(date +%F).dump
sudo -u postgres pg_dumpall --globals-only > /root/pg_globals_$(date +%F).sql
```

Node maintenance: switchover (if it is the leader) → stop services → do the work → start; Patroni will bring the node back as a replica automatically.

## 10. Failure Behaviour

| Scenario | What happens | Alert |
|----------|--------------|-------|
| node1 fails (leader + active) | node2 → DB leader, VIP moves to node2, zabbix node2 → active (after failover delay) | "node1 unavailable" in Telegram |
| node2 fails (standby + replica) | node1 keeps working, etcd quorum alive | "node2 unavailable" |
| Node returns | rejoins as replica + standby; the VIP may return to node1 by priority | — |
| node3 fails (witness) | DB/server keep working (quorum node1+node2), no quorum reserve — bring node3 back | mutual monitoring |
| Whole cluster fails | monitoring is down | watchdog node3 → 🔴 Telegram |

## 11. Troubleshooting Common Issues

- **etcd "cluster ID mismatch"** — different `initial-cluster-token` / member list. Use one token `zabbix-cluster`, the same list of 3, a clean data-dir, and start close together in time.
- **Wiping etcd data-dir doesn't work** — the directory is `700 etcd:etcd`, and the mask is expanded by an unprivileged shell. Clean it as root: `sudo rm -rf /var/lib/etcd && sudo mkdir … && chown etcd:etcd`.
- **keepalived "invalid passwd" + VIP on both** — different `auth_pass`, OR a foreign VRRP instance with the same `virtual_router_id` (virtual MAC conflict). Keep the password identical and the VRID unique (231).
- **HAProxy not listening on 5000** — after editing the config you must `systemctl restart haproxy`.
- **Web 502 / no socket** — missing php-fpm pool `/etc/php/8.2/fpm/pool.d/zabbix.conf`.
- **Patroni stuck at "creating replica"** — an interrupted `pg_basebackup`: stop Patroni → `pkill -u postgres` → clear the data_dir → start.
- **Zabbix "database error"** — check `DBHost=172.19.0.24` and `DBPort=5000` in `zabbix_server.conf` and `zabbix.conf.php` on both nodes.
- **Watchdog silent** — Telegram works only through the proxy; check `curl -x socks5h://<SOCKS_PROXY_HOST:PORT> …`; do not delete the `/tmp/zbx_cluster_down` flag between "down" and "recovery".
