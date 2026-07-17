# Описание скриптов

Все скрипты определяют роль узла по наличию VIP `172.19.3.202` и защищены
lock-файлом от повторного запуска. Уведомления об ошибках уходят в Telegram.

---

## 1. `scripts/sync_from_202.sh` → `/root/sync_from_202.sh`

**Назначение.** Синхронизирует данные Asterisk с мастера (.202) на бэкап:

- CDR (история звонков), таблица `asteriskcdrdb.cdr`;
- CEL (детальные события), таблица `asteriskcdrdb.cel`;
- `/var/spool/asterisk/monitor` (записи разговоров) через rsync.

**Работает только если** локальный узел НЕ держит VIP и мастер доступен по SSH.

**Логика.** Берёт максимальный timestamp локальных CDR/CEL и тянет с мастера только
более новые строки (инкрементально, `mysqldump --where`). Записи копируются
`rsync --ignore-existing`.

**Cron:** `*/5 * * * *` → лог `/var/log/pbx_sync.log`.

**Telegram при ошибках:**
- `PBX SYNC ERROR: SSH недоступен (172.19.3.202)`
- `PBX SYNC ERROR: CDR sync failed (...)`
- `PBX SYNC ERROR: CEL sync failed (...)`
- `PBX SYNC ERROR: ошибка rsync monitor (rc=XX)`

**За чем следить:** нет ошибок SSH/MySQL, логичная динамика CDR/CEL, отсутствие
массовых ошибок rsync кроме `rc=24` (норма для «живой» системы).

---

## 2. `scripts/sync_freepbx_config.sh` → `/root/sync_freepbx_config.sh`

**Назначение.** Синхронизирует конфигурацию FreePBX (БД `asterisk`): маршруты
inbound/outbound, extensions, очереди, ring groups, IVR, miscapps, outbound CID и т.д.
Список формируется через `SHOW TABLES`, с исключениями.

**Исключаемые таблицы** (не трогаются): `modules`, `freepbx_settings`, `admin`,
`cronmanager`, `kvstore`.

**Логика.** По каждой таблице: `TRUNCATE` локально → `mysqldump` с мастера → импорт.
Дополнительно синхронизирует `sounds/ru/custom`. Если были изменения — выполняет
`fwconsole reload`.

**Работает только если** локальный узел НЕ держит VIP и мастер доступен по SSH.

**Cron:** `0 * * * *` → лог `/var/log/pbx_sync_config.log`.

**Telegram при ошибках:**
- `CONFIG SYNC ERROR: SSH недоступен (172.19.3.202)`
- `CONFIG SYNC ERROR: cannot read local DB`
- `CONFIG SYNC ERROR: table <T> failed (...)`
- `CONFIG SYNC ERROR: fwconsole reload failed (...)`

**За чем следить:** таблицы синхронизируются каждый час, нет MySQL-ошибок,
`fwconsole reload` завершается успешно.

---

## 3. `scripts/pbx_failover.sh` → `/usr/local/sbin/pbx_failover.sh`

**Назначение.** Автоматический failover. Проверяет мастер `172.19.3.202` по **ping**
и **SSH (порт 22)**. Если мастер недоступен `FAIL_THRESHOLD` циклов подряд (по умолчанию 2),
узел забирает VIP и становится MASTER.

**Действия при failover:**
1. удаляет BACKUP IP `172.19.3.203/24`;
2. назначает MASTER IP `172.19.3.202/24`;
3. восстанавливает default gateway `172.19.3.1`;
4. делает ARP refresh (`arping -A` / `-U`), чтобы обновить таблицы у коммутаторов;
5. шлёт уведомление в Telegram.

**Защита от «дрожания» (flapping):** счётчик неудач хранится в
`/var/run/pbx_failover_failcount` и сбрасывается при восстановлении мастера.
Если мастер пингуется, но SSH молчит — failover НЕ выполняется (счётчик сбрасывается).

**Cron:** `* * * * *` (каждую минуту) → лог `/var/log/pbx_failover.log`.

**Telegram:** `FAILOVER: PBX203 ПОЛУЧИЛ РОЛЬ MASTER. Назначен IP 172.19.3.202. Gateway 172.19.3.1.`

**Параметры вверху скрипта:** `FAIL_THRESHOLD`, `PING_COUNT`, `PING_TIMEOUT`, `IFACE`,
`GATEWAY`, `NODE_NAME`.

**За чем следить:** failover не должен происходить часто; ping+SSH стабильны;
IP `172.19.3.202` не появляется одновременно на двух нодах.

---

## 4. `scripts/pbx_reverse_sync.sh` → `/root/pbx_reverse_sync.sh`

**Назначение.** Ручная **обратная** синхронизация: переносит актуальные данные с .203
(временно ставшего мастером) обратно на вернувшийся .202. Пушит конфиг, CDR, CEL,
записи и custom-звуки, затем делает удалённый `fwconsole reload`.

**Работает только если** VIP `172.19.3.202` поднят локально (то есть текущий узел —
действующий мастер, откуда возвращаем данные).

**Запуск:** только вручную, уведомления шлёт лишь при ошибках → лог
`/var/log/pbx_reverse_sync.log`.

**За чем следить:** выполнение без MySQL-ошибок, актуальность данных после возврата ролей.
