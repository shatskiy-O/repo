# Мониторинг: логи и Telegram-уведомления

## Логи

| Лог | Скрипт | Что смотреть |
|---|---|---|
| `/var/log/pbx_failover.log` | pbx_failover.sh | регулярные проверки, отсутствие частых failover и «flapping» |
| `/var/log/pbx_sync.log` | sync_from_202.sh | синх CDR/CEL/записей, ошибки SSH/MySQL/rsync |
| `/var/log/pbx_sync_config.log` | sync_freepbx_config.sh | синх таблиц FreePBX, результат `fwconsole reload` |
| `/var/log/pbx_reverse_sync.log` | pbx_reverse_sync.sh | результат ручного обратного переноса |

Быстрый просмотр:

```bash
tail -f /var/log/pbx_failover.log
tail -n 100 /var/log/pbx_sync.log
grep -i error /var/log/pbx_sync_config.log
```

## Полный список Telegram-уведомлений

**Failover:**
```
FAILOVER: PBX203 ПОЛУЧИЛ РОЛЬ MASTER. Назначен IP 172.19.3.202. Gateway 172.19.3.1.
```

**Ошибки синхронизации данных (sync_from_202.sh):**
```
PBX SYNC ERROR: SSH недоступен (172.19.3.202)
PBX SYNC ERROR: CDR sync failed (dump=.. import=..)
PBX SYNC ERROR: CEL sync failed (dump=.. import=..)
PBX SYNC ERROR: ошибка rsync monitor (rc=XX)
```

**Ошибки синхронизации конфигурации (sync_freepbx_config.sh):**
```
CONFIG SYNC ERROR: SSH недоступен (172.19.3.202)
CONFIG SYNC ERROR: cannot read local DB
CONFIG SYNC ERROR: table <T> failed (dump=.. import=..)
CONFIG SYNC ERROR: fwconsole reload failed (rc=XX)
```

**Ошибки обратной синхронизации (pbx_reverse_sync.sh):**
```
❗ Reverse SYNC ERROR: ...
```

> Любое сообщение вида `... ERROR:` — повод проверить мастер и соответствующий лог.

## На что обращать внимание

- **Частота failover.** Несколько failover подряд = нестабильная сеть/мастер. Проверьте
  ping и SSH, при необходимости увеличьте `FAIL_THRESHOLD` в `pbx_failover.sh`.
- **Двойной мастер.** IP `172.19.3.202` не должен одновременно быть на .202 и .203.
- **rsync rc=24** — норма (файлы исчезли во время копирования на «живой» системе),
  не считается ошибкой.
- **Ноль импортированных строк** при синхронизации конфига, хотя на мастере были
  изменения — повод разобраться.
