# Развёртывание с нуля

Инструкция ставит стек на чистые серверы. Если система уже есть — см. [OPERATIONS.md](OPERATIONS.md).

## Предпосылки

- **АТС**: FreePBX / Asterisk, MariaDB 10.x, root-доступ к MariaDB, ssh-доступ с sudo.
- **VM с Grafana**: Debian 11+ / Ubuntu 22.04+, Docker + Docker Compose plugin, `autossh`, `jq`, `mysql-client`.

## Шаг 0. Клонируем репозиторий на VM

```bash
cd /opt
sudo git clone https://github.com/shatskiy-O/repo.git shatskiy-repo
cd shatskiy-repo/callstats-grafana
sudo cp .env.example .env
sudo chmod 600 .env
sudo nano .env   # заполнить пароли, IP, порт
```

## Шаг 1. Настройка на АТС

Всё делаем от root АТС.

### 1.1. База данных и пользователи

```bash
# Скопируем SQL c VM на АТС (или редактируем прямо на АТС)
scp ats/sql/01_schema.sql root@<ATS_HOST>:/tmp/

# На АТС: подставляем пароли и запускаем от root MariaDB
ssh root@<ATS_HOST>
sed -i "s/\${CALLSTATS_WRITER_PASS}/PASTE_WRITER_PASS/g" /tmp/01_schema.sql
sed -i "s/\${CALLSTATS_RO_PASS}/PASTE_RO_PASS/g"         /tmp/01_schema.sql

mysql -uroot -p < /tmp/01_schema.sql
shred -u /tmp/01_schema.sql
```

### 1.2. Пароль writer'а в конфиг

На АТС:

```bash
cat > /root/.callstats_db.conf <<EOF
CALLSTATS_DB_PASS=PASTE_WRITER_PASS
EOF
chmod 600 /root/.callstats_db.conf
```

### 1.3. Устанавливаем ETL

```bash
# Копируем скрипт и SQL на АТС
scp ats/sql/callstats_rebuild_2d.sql root@<ATS_HOST>:/usr/local/bin/
scp ats/scripts/callstats_update.sh   root@<ATS_HOST>:/usr/local/bin/
scp ats/scripts/callstats_update.cron root@<ATS_HOST>:/etc/cron.d/callstats_update

ssh root@<ATS_HOST> "chmod +x /usr/local/bin/callstats_update.sh \
                     && chmod 644 /etc/cron.d/callstats_update"
```

### 1.4. Проверка ETL

На АТС:

```bash
/usr/local/bin/callstats_update.sh
tail -n 5 /var/log/callstats_update.log

mysql -ucallstats_writer -p callstats <<'SQL'
SELECT disposition, COUNT(*) FROM queue_calls
WHERE enter_ts >= NOW() - INTERVAL 1 DAY
GROUP BY disposition;
SQL
```

Должны появиться строки. Если нет — смотри [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### 1.5. Пользователь для SSH-туннеля

На АТС:

```bash
adduser --disabled-password --shell /bin/false --gecos "Grafana tunnel" grafana

# Публичный ключ с VM (см. Шаг 2.1) кладём в:
mkdir -p /home/grafana/.ssh
chmod 700 /home/grafana/.ssh
touch /home/grafana/.ssh/authorized_keys
chmod 600 /home/grafana/.ssh/authorized_keys
chown -R grafana:grafana /home/grafana/.ssh

# Ограничим ключ только туннелем — добавим prefix в authorized_keys:
# no-agent-forwarding,no-X11-forwarding,no-pty,permitopen="127.0.0.1:3306" <ключ>
```

## Шаг 2. Настройка на VM с Grafana

### 2.1. SSH-ключ для туннеля

```bash
sudo -u tor ssh-keygen -t rsa -b 4096 -N "" -f /home/tor/.ssh/ats_grafana_rsa
cat /home/tor/.ssh/ats_grafana_rsa.pub
# ↑ этот public key копируем в /home/grafana/.ssh/authorized_keys на АТС (Шаг 1.5)

# Проверка коннекта
sudo -u tor ssh -i /home/tor/.ssh/ats_grafana_rsa -o StrictHostKeyChecking=accept-new \
  grafana@<ATS_HOST> "echo OK"
```

### 2.2. systemd unit для туннеля

```bash
# Подставляем ATS_HOST в шаблон
sudo sed "s/ATS_HOST_PLACEHOLDER/<ATS_HOST>/g" \
  grafana/systemd/ats-mysql-tunnel.service \
  | sudo tee /etc/systemd/system/ats-mysql-tunnel.service >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable --now ats-mysql-tunnel.service
sudo systemctl status ats-mysql-tunnel.service --no-pager

# Проверка
ss -lntp | grep 3307
mysql -h 127.0.0.1 -P 3307 --protocol=tcp -ucallstats_ro -p callstats \
  -e "SELECT COUNT(*) FROM queue_daily;"
```

### 2.3. Grafana в Docker

```bash
sudo mkdir -p /opt/grafana/{data,dashboards,provisioning/datasources,provisioning/dashboards}
sudo chown -R 472:472 /opt/grafana/data   # пользователь grafana в контейнере

# Копируем provisioning и compose
sudo cp grafana/provisioning/datasources/callstats.yaml        /opt/grafana/provisioning/datasources/
sudo cp grafana/provisioning/dashboards/callstats-provider.yaml /opt/grafana/provisioning/dashboards/
sudo cp grafana/compose/docker-compose.yml                     /opt/grafana/

# Копируем .env (пароли в контейнер прилетают отсюда)
sudo cp .env /opt/grafana/.env
sudo chmod 600 /opt/grafana/.env

# Дашборды
sudo cp grafana/dashboards/*.json /opt/grafana/dashboards/

# Старт
cd /opt/grafana
sudo docker compose up -d
sudo docker ps | grep grafana
```

### 2.4. Русский язык

Открыть в браузере `http://<GF_HOST>:3000`, войти под admin. Пароль из `.env` (`GF_ADMIN_PASSWORD`). Затем:

```bash
# Из шелла VM: устанавливаем ru-RU на уровне организации
curl -sS -u "admin:$(grep ^GF_ADMIN_PASSWORD .env | cut -d= -f2)" \
  -H 'Content-Type: application/json' \
  -X PUT http://127.0.0.1:3000/api/org/preferences \
  -d '{"language":"ru-RU","weekStart":"monday","theme":""}'
```

В браузере: Ctrl+F5.

### 2.5. Проверка

```bash
sudo ./tools/healthcheck.sh
```

Все 4 блока должны быть зелёными.

## Шаг 3. Первый бэкап

```bash
sudo ./tools/backup.sh
ls -la /opt/grafana/backup_GOLDEN_*
```

Готово. Дашборды в разделе Callstats: `http://<GF_HOST>:3000/dashboards`.

## Пересборка дашбордов из Python

Если нужно поправить SQL или добавить панель, редактируем `tools/build_dashboards.py`, регенерируем JSON и перезапускаем контейнер:

```bash
cd callstats-grafana/tools
python3 build_dashboards.py ../grafana/dashboards

sudo cp ../grafana/dashboards/*.json /opt/grafana/dashboards/
sudo docker restart grafana
```
