# Эксплуатация

## Ежедневный чек-лист

```bash
sudo /opt/shatskiy-repo/callstats-grafana/tools/healthcheck.sh
```

Если что-то красное — см. [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Обновление дашбордов

Из репозитория, с VM:

```bash
cd /opt/shatskiy-repo
sudo git pull

# Перед накаткой — бэкап
sudo callstats-grafana/tools/backup.sh

# Накатываем новые JSON
sudo cp callstats-grafana/grafana/dashboards/*.json /opt/grafana/dashboards/

# Grafana подхватит сама (провижининг с updateIntervalSeconds: 30),
# но можно и рестартнуть для гарантии:
sudo docker restart grafana
```

## Обновление ETL на АТС

```bash
# С VM копируем свежие SQL и shell на АТС
scp callstats-grafana/ats/sql/callstats_rebuild_2d.sql root@<ATS>:/usr/local/bin/
scp callstats-grafana/ats/scripts/callstats_update.sh   root@<ATS>:/usr/local/bin/
ssh root@<ATS> "chmod +x /usr/local/bin/callstats_update.sh"

# Прогон вручную для проверки
ssh root@<ATS> "/usr/local/bin/callstats_update.sh && tail -n 3 /var/log/callstats_update.log"
```

## Бэкапы

**Создать golden-бэкап** (перед любой рискованной операцией):

```bash
sudo /opt/shatskiy-repo/callstats-grafana/tools/backup.sh
```

Результат: `/opt/grafana/backup_GOLDEN_<timestamp>/` с `dashboards/`, `provisioning/`, `docker-compose.yml`, `SHA256SUMS.txt`, `README.txt`.

**Расписание бэкапов** (крон, если нужно):

```
# /etc/cron.d/grafana-backup
0 4 * * *  root  /opt/shatskiy-repo/callstats-grafana/tools/backup.sh >>/var/log/grafana-backup.log 2>&1
```

**Ротация**: старые бэкапы удаляем вручную по мере накопления. Или добавить в cron:

```bash
find /opt/grafana -maxdepth 1 -type d -name 'backup_GOLDEN_*' -mtime +30 -exec rm -rf {} \;
```

## Откат

Смотрим список:

```bash
ls -1d /opt/grafana/backup_GOLDEN_*
```

Откатываемся:

```bash
sudo /opt/shatskiy-repo/callstats-grafana/tools/restore.sh /opt/grafana/backup_GOLDEN_2026-05-15_1440
```

`restore.sh` перед накатом сохранит текущее состояние в `backup_before_restore_<ts>` — если откат не помог, можно вернуться назад тем же restore.sh на этот новый snapshot.

## Смена пароля read-only пользователя Grafana

**На АТС:**

```sql
ALTER USER 'callstats_ro'@'%' IDENTIFIED BY 'NEW_STRONG_PASS';
FLUSH PRIVILEGES;
```

**На VM:**

```bash
sudo nano /opt/grafana/.env
# CALLSTATS_RO_PASS=NEW_STRONG_PASS

sudo docker restart grafana
```

## Смена пароля admin Grafana

```bash
sudo docker exec -it grafana grafana cli admin reset-admin-password NEW_STRONG_PASS
```

Или через `.env` (при первом запуске Grafana):

```bash
sudo nano /opt/grafana/.env
# GF_ADMIN_PASSWORD=NEW_STRONG_PASS
sudo docker restart grafana
```

Обрати внимание: `GF_SECURITY_ADMIN_PASSWORD` через env работает **только при инициализации** контейнера. Смена уже созданного пароля — через `grafana cli`.

## Мониторинг

**Логи ETL на АТС:**

```
/var/log/callstats_update.log
```

**Логи Grafana:**

```bash
sudo docker logs -f grafana
```

**Логи туннеля:**

```bash
sudo journalctl -u ats-mysql-tunnel.service -n 200 --no-pager
```

**Метрики свежести**: healthcheck.sh проверяет, что последний звонок был не более 15 минут назад. Порог можно поднять, если очередей мало и звонки редкие.

## Расширение отчёта — добавление новых KPI

1. Отредактировать `tools/build_dashboards.py` — добавить панель через `stat_panel/bar_panel/table_panel/…`.
2. Сгенерировать: `python3 tools/build_dashboards.py grafana/dashboards`.
3. Проверить JSON: `jq . grafana/dashboards/callstats-load.json >/dev/null`.
4. Закоммитить в git.
5. Задеплоить: `sudo cp grafana/dashboards/*.json /opt/grafana/dashboards/ && sudo docker restart grafana`.

## Тесты вручную

Из VM проверить один запрос через Grafana API:

```bash
source /opt/grafana/.env
curl -sS -u "admin:${GF_ADMIN_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:3000/api/ds/query \
  -d '{
    "queries": [{
      "refId":"A",
      "datasource":{"type":"mysql","uid":"PC8CDFBD862B3D820"},
      "rawSql":"SELECT NOW() AS time, COUNT(*) AS calls FROM queue_calls WHERE enter_ts >= NOW() - INTERVAL 1 DAY",
      "format":"time_series"
    }],
    "from":"now-1d","to":"now"
  }' | jq
```
