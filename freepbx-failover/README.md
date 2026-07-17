# FreePBX Failover 172.19.3.202 ↔ 172.19.3.203

> 🇷🇺 Русский (ниже) · 🇬🇧 [English](#-english)

Автоматический failover и синхронизация двух узлов FreePBX/Asterisk с уведомлениями в Telegram.

---

## 🇷🇺 Русский

### Что это

Отказоустойчивая пара FreePBX:

- **PBX1 — `172.19.3.202`** — MASTER (держит рабочий VIP телефонии).
- **PBX2 — `172.19.3.203`** — BACKUP (в горячем резерве, тянет данные с мастера).

Роль узла определяется **наличием IP `172.19.3.202`** на интерфейсе:
если адрес есть — узел MASTER, если нет — BACKUP. На обеих нодах установлен
одинаковый набор скриптов и cron; поведение выбирается автоматически.

```
             VIP 172.19.3.202  (рабочий IP телефонии)
                      │
             ┌────────┴────────┐
             │   SIP-провайдеры │
             └────────┬────────┘
                      │
        ┌─────────────▼─────────────┐
        │  ACTIVE MASTER  .202       │
        └─────────────┬─────────────┘
                      │  ← синхронизация CDR/CEL/конфиг/записи
        ┌─────────────▼─────────────┐
        │  BACKUP NODE    .203       │
        └───────────────────────────┘
```

### Состав репозитория

```
freepbx-failover/
├── README.md                     — этот файл (RU + EN)
├── scripts/
│   ├── pbx_failover.sh           — авто-failover (захват VIP)      → /usr/local/sbin/
│   ├── sync_from_202.sh          — синх CDR/CEL/записей с мастера   → /root/
│   ├── sync_freepbx_config.sh    — синх конфигурации FreePBX        → /root/
│   └── pbx_reverse_sync.sh       — ручная обратная синхронизация    → /root/
├── cron/
│   └── crontab.example           — строки cron для обеих нод
└── docs/
    ├── ARCHITECTURE.md           — архитектура и логика ролей
    ├── SCRIPTS.md                — подробное описание каждого скрипта
    ├── FAILOVER_SCENARIOS.md     — аварийные сценарии и возврат ролей
    └── MONITORING.md             — логи, Telegram-уведомления, что мониторить
```

### ⚠️ Перед публикацией — настройка секретов

Во всех скриптах чувствительные значения заменены на **заглушки**. Перед боевым
использованием подставьте свои значения (и **не коммитьте** их в публичный репозиторий):

| Плейсхолдер | Что это | Где |
|---|---|---|
| `CHANGE_ME_DB_PASSWORD` | пароль MySQL (`root`) | все sync-скрипты |
| `CHANGE_ME_TELEGRAM_BOT_TOKEN` | токен Telegram-бота | все скрипты |
| `CHANGE_ME_TELEGRAM_CHAT_ID` | ID чата/группы Telegram | все скрипты |

SSH-ключ (`/root/.ssh/id_rsa`) в репозиторий **не входит** — узлы должны иметь
взаимный доступ root по ключу.

### Быстрая установка

```bash
# на BACKUP-ноде (.203)
install -m 0755 scripts/pbx_failover.sh      /usr/local/sbin/pbx_failover.sh
install -m 0755 scripts/sync_from_202.sh     /root/sync_from_202.sh
install -m 0755 scripts/sync_freepbx_config.sh /root/sync_freepbx_config.sh
install -m 0755 scripts/pbx_reverse_sync.sh  /root/pbx_reverse_sync.sh

# подставить секреты в каждом файле, затем добавить cron (см. cron/crontab.example)
crontab -e
```

Подробности — в [docs/](docs/).

---

## 🇬🇧 English

### Overview

A high-availability FreePBX/Asterisk pair with automatic failover and Telegram alerts:

- **PBX1 — `172.19.3.202`** — MASTER, holds the telephony VIP.
- **PBX2 — `172.19.3.203`** — BACKUP, hot standby that pulls data from the master.

A node's role is decided by **whether IP `172.19.3.202` is present** on its interface:
if the address is there, the node is MASTER; if not, it is BACKUP. Both nodes carry
the same scripts and cron; behaviour is selected automatically.

### Repository layout

```
freepbx-failover/
├── scripts/
│   ├── pbx_failover.sh           — automatic failover (VIP takeover) → /usr/local/sbin/
│   ├── sync_from_202.sh          — pull CDR/CEL/recordings from master → /root/
│   ├── sync_freepbx_config.sh    — pull FreePBX config tables          → /root/
│   └── pbx_reverse_sync.sh       — manual reverse sync                 → /root/
├── cron/crontab.example
└── docs/                         — architecture, scripts, scenarios, monitoring (RU)
```

### ⚠️ Secrets before publishing

All sensitive values are replaced with placeholders. Substitute your own before use
and never commit them to a public repo:

| Placeholder | Meaning |
|---|---|
| `CHANGE_ME_DB_PASSWORD` | MySQL `root` password |
| `CHANGE_ME_TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `CHANGE_ME_TELEGRAM_CHAT_ID` | Telegram chat/group ID |

The SSH key (`/root/.ssh/id_rsa`) is **not** included; nodes must have mutual
key-based root access.

### Roles at a glance

```
Normal:            .202 = MASTER, .203 = BACKUP
Failover:          .202 down → .203 takes VIP → MASTER
Recovery of .202:  give it IP .203 → auto BACKUP
Manual switchback: stop .203, set IP .202 → MASTER; .203 → BACKUP
```

Detailed docs (in Russian) live in [docs/](docs/).
