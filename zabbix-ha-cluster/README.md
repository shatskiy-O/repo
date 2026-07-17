<h1 align="center">Zabbix HA Cluster «Terem Zabbix»</h1>

<p align="center">
  Отказоустойчивый Zabbix: реплицируемая БД (Patroni + etcd), native HA сервера,<br>
  плавающий VIP, дублированный веб-интерфейс и внешний heartbeat в Telegram.
</p>

<p align="center">
  <a href="zabbix-ha-cluster-wiki.md"><b>🇷🇺 Русская версия</b></a>
  &nbsp;·&nbsp;
  <a href="Zabbix_HA_Cluster_EN.md"><b>🇬🇧 English version</b></a>
</p>

---

## 📖 Документация · Documentation

| Язык / Language | Файл / File | Описание / Description |
|:---:|:---|:---|
| 🇷🇺 Русский | **[zabbix-ha-cluster-wiki.md](zabbix-ha-cluster-wiki.md)** | Полное описание архитектуры, конфигов и процедур |
| 🇬🇧 English | **[Zabbix_HA_Cluster_EN.md](Zabbix_HA_Cluster_EN.md)** | Full description of architecture, configs and procedures |

---

## 🧭 Что внутри · What's inside

Оба документа содержат одно и то же (на своём языке) / Both documents cover the same content:

- **Архитектура / Architecture** — схема кластера, слои отказоустойчивости.
- **Узлы, адреса, версии ПО / Nodes, addresses, software versions.**
- **Сервисы и порты / Services and ports.**
- **Полные конфиги / Full configs** — etcd, Patroni, HAProxy, keepalived, Zabbix server, frontend, agent2.
- **Оповещения / Alerting** — Telegram через SOCKS-прокси, взаимный мониторинг, внешний watchdog.
- **Проверка здоровья / Health-check cheat sheet.**
- **Типовые операции и поведение при отказах / Common operations & failure behaviour.**
- **Диагностика частых проблем / Troubleshooting.**

---

## 🗺️ Обзор архитектуры · Architecture at a glance

```
        VIP 172.19.0.24  (keepalived, VRID 231)
        HAProxy :5000 → текущий Patroni-лидер
                 ▲                     ▲
      ┌──────────┴─────────┐ ┌─────────┴──────────┐
      │ node1  172.19.0.38 │ │ node2  172.19.0.37 │
      │ PG Leader (active) │ │ PG Replica (standby)│
      └──────────┬─────────┘ └─────────┬──────────┘
                 └──── etcd quorum ─────┘
                          │
                 ┌────────┴─────────┐
                 │ node3 10.0.1.60  │
                 │ etcd witness +   │
                 │ watchdog→Telegram│
                 └──────────────────┘
```