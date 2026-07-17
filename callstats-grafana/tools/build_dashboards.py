#!/usr/bin/env python3
# =============================================================================
# callstats-grafana / tools / build_dashboards.py
#
# Генерирует три JSON-дашборда Grafana:
#   - callstats-load.json    "Колл-центр — Нагрузка"
#   - callstats-queues.json  "Колл-центр — Очереди"
#   - callstats-agent.json   "Колл-центр — Оператор"
#
# Все SQL-запросы совместимы с Grafana 12.x (см. docs/SQL_NOTES.md):
#   * поля time обёрнуты в CAST(... AS DATETIME)
#   * фильтры используют LIKE '${queue:raw}' / LIKE '${agent:raw}'
#   * heatmap-метки сортируются лексикографически (LPAD)
#
# Запуск:
#   python3 build_dashboards.py [OUTPUT_DIR]
#
# По умолчанию пишет в ./dashboards рядом со скриптом.
# =============================================================================
import json
import pathlib
import sys

DS_UID = "PC8CDFBD862B3D820"
DS = {"type": "mysql", "uid": DS_UID}

# Фильтр, общий для всех time-based SQL: очередь + опциональный оператор
WHERE_QA = (
    "$__timeFilter(enter_ts) "
    "AND queuename LIKE '${queue:raw}' "
    "AND (agent LIKE '${agent:raw}' OR agent IS NULL OR agent = '')"
)

# --- порог для heatmap-корзины «долгого ожидания» --------------------
HEATMAP_CAP_SEC = 120


# ============================================================================
# Утилиты построения панелей
# ============================================================================
def templating():
    return {"list": [
        {
            "name": "queue", "label": "Очередь", "type": "query",
            "datasource": DS, "refresh": 2,
            "query":      "SELECT DISTINCT queuename FROM queue_daily ORDER BY queuename",
            "definition": "SELECT DISTINCT queuename FROM queue_daily ORDER BY queuename",
            "multi": False, "includeAll": True, "allValue": "%",
            "current": {"text": "Все", "value": "$__all"},
        },
        {
            "name": "agent", "label": "Оператор", "type": "query",
            "datasource": DS, "refresh": 2,
            "query": ("SELECT DISTINCT agent FROM queue_calls "
                      "WHERE agent IS NOT NULL AND agent<>'' "
                      "AND queuename LIKE '${queue:raw}' ORDER BY agent"),
            "definition": ("SELECT DISTINCT agent FROM queue_calls "
                           "WHERE agent IS NOT NULL AND agent<>'' "
                           "AND queuename LIKE '${queue:raw}' ORDER BY agent"),
            "multi": False, "includeAll": True, "allValue": "%",
            "current": {"text": "Все", "value": "$__all"},
        },
    ]}


def base_panel(pid, ptype, title, grid, sql, fmt="table"):
    return {
        "id": pid, "type": ptype, "title": title, "gridPos": grid,
        "datasource": DS,
        "targets": [{
            "refId": "A", "datasource": DS, "rawQuery": True,
            "rawSql": sql, "format": fmt,
        }],
        "fieldConfig": {"defaults": {}, "overrides": []},
        "options": {},
    }


def stat_panel(pid, title, grid, sql, unit=None, decimals=None):
    p = base_panel(pid, "stat", title, grid, sql, fmt="table")
    p["options"] = {
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
        "orientation": "auto", "textMode": "auto", "colorMode": "value",
        "graphMode": "none", "justifyMode": "auto",
    }
    if unit:
        p["fieldConfig"]["defaults"]["unit"] = unit
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    return p


def bar_panel(pid, title, grid, sql, x_field):
    p = base_panel(pid, "barchart", title, grid, sql, fmt="table")
    p["options"] = {
        "xField": x_field, "orientation": "vertical",
        "groupWidth": 0.7, "barWidth": 0.97,
        "showValue": "auto", "stacking": "none",
        "legend": {"showLegend": True, "displayMode": "list", "placement": "bottom"},
        "tooltip": {"mode": "multi", "sort": "none"},
    }
    return p


def timeseries_panel(pid, title, grid, sql, unit=None):
    p = base_panel(pid, "timeseries", title, grid, sql, fmt="time_series")
    p["options"] = {
        "legend": {"showLegend": True, "displayMode": "list",
                   "placement": "bottom", "calcs": []},
        "tooltip": {"mode": "multi", "sort": "none"},
    }
    p["fieldConfig"]["defaults"]["custom"] = {
        "drawStyle": "line", "lineInterpolation": "smooth", "lineWidth": 2,
        "fillOpacity": 10, "showPoints": "auto", "spanNulls": True,
    }
    if unit:
        p["fieldConfig"]["defaults"]["unit"] = unit
    return p


def table_panel(pid, title, grid, sql):
    p = base_panel(pid, "table", title, grid, sql, fmt="table")
    p["options"] = {
        "showHeader": True, "cellHeight": "sm",
        "footer": {"countRows": False, "reducer": ["sum"],
                   "show": False, "fields": ""},
    }
    return p


def heatmap_panel(pid, title, grid, sql):
    p = base_panel(pid, "heatmap", title, grid, sql, fmt="time_series")
    p["options"] = {
        "calculate": False,
        "calculation": {
            "xBuckets": {"mode": "size", "value": ""},
            "yBuckets": {"mode": "size", "value": "",
                         "scale": {"type": "linear", "log": 2}},
        },
        "cellGap": 1, "cellRadius": 0,
        "cellValues": {"unit": "short"},
        "color": {
            "mode": "scheme", "scheme": "Oranges", "fill": "dark-orange",
            "exponent": 0.5, "steps": 64, "reverse": False,
            "min": None, "max": None,
        },
        "exemplars": {"color": "rgba(255,0,255,0.7)"},
        "filterValues": {"le": 1e-9},
        "legend": {"show": True},
        "rowsFrame": {"layout": "auto"},
        "showValue": "never",
        "tooltip": {"mode": "single", "yHistogram": False,
                    "showColorScale": False},
        "yAxis": {"axisPlacement": "left", "reverse": False, "unit": "short"},
    }
    p["fieldConfig"] = {
        "defaults": {
            "custom": {
                "scaleDistribution": {"type": "linear"},
                "hideFrom": {"tooltip": False, "viz": False, "legend": False},
            }
        },
        "overrides": [],
    }
    return p


def dashboard(uid, title, panels, tags, time_from="now-7d"):
    return {
        "uid": uid, "title": title,
        "timezone": "browser",
        "schemaVersion": 41, "version": 1,
        "refresh": "30s",
        "tags": tags,
        "time": {"from": time_from, "to": "now"},
        "templating": templating(),
        "panels": panels,
        "annotations": {"list": []},
        "editable": True, "graphTooltip": 0,
        "fiscalYearStartMonth": 0, "liveNow": False,
        "weekStart": "monday",
    }


# ============================================================================
# SQL: heatmap с клиппингом длинных ожиданий в верхний бакет
# ============================================================================
def heatmap_sql():
    return (
        "SELECT\n"
        "  FROM_UNIXTIME(FLOOR(UNIX_TIMESTAMP(enter_ts)/900)*900) AS time,\n"
        f"  CASE WHEN TIMESTAMPDIFF(SECOND, enter_ts, connect_ts) > {HEATMAP_CAP_SEC}\n"
        "       THEN '>120'\n"
        "       ELSE LPAD(FLOOR(TIMESTAMPDIFF(SECOND, enter_ts, connect_ts)/5)*5, 5, '0')\n"
        "  END AS metric,\n"
        "  COUNT(*) AS value\n"
        "FROM queue_calls\n"
        "WHERE $__timeFilter(enter_ts)\n"
        "  AND disposition='ANSWERED'\n"
        "  AND connect_ts IS NOT NULL\n"
        "  AND queuename LIKE '${queue:raw}'\n"
        "  AND agent LIKE '${agent:raw}'\n"
        "GROUP BY time, metric\n"
        "ORDER BY time, metric"
    )


# ============================================================================
# Дашборд 1: Колл-центр — Нагрузка
# ============================================================================
def build_load():
    p = []

    # Ряд 1 — сводные числа
    p.append(stat_panel(1, "Получено",
        {"x": 0, "y": 0, "w": 4, "h": 4},
        f"SELECT COUNT(*) AS value FROM queue_calls WHERE {WHERE_QA}"))
    p.append(stat_panel(2, "Отвечено",
        {"x": 4, "y": 0, "w": 4, "h": 4},
        f"SELECT COUNT(*) AS value FROM queue_calls "
        f"WHERE {WHERE_QA} AND disposition='ANSWERED'"))
    p.append(stat_panel(3, "Неотвечено (ABANDON)",
        {"x": 8, "y": 0, "w": 4, "h": 4},
        f"SELECT COUNT(*) AS value FROM queue_calls "
        f"WHERE {WHERE_QA} AND disposition='ABANDON'"))
    p.append(stat_panel(4, "Несостоявшийся",
        {"x": 12, "y": 0, "w": 4, "h": 4},
        f"SELECT COUNT(*) AS value FROM queue_calls "
        f"WHERE {WHERE_QA} AND disposition IN "
        f"('ABANDON','EXITWITHTIMEOUT','EXITEMPTY')"))
    p.append(stat_panel(5, "% Отвеченных",
        {"x": 16, "y": 0, "w": 4, "h": 4},
        f"SELECT ROUND(SUM(disposition='ANSWERED')/NULLIF(COUNT(*),0)*100,1) "
        f"AS value FROM queue_calls WHERE {WHERE_QA}",
        unit="percent", decimals=1))
    p.append(stat_panel(6, "Ср. ожидание",
        {"x": 20, "y": 0, "w": 4, "h": 4},
        f"SELECT ROUND(AVG(TIMESTAMPDIFF(SECOND, enter_ts, connect_ts)),1) "
        f"AS value FROM queue_calls WHERE {WHERE_QA} AND disposition='ANSWERED'",
        unit="s"))

    # Ряд 2 — по неделям
    p.append(timeseries_panel(10,
        "Нагрузка по неделям (Получено / Отвечено / Неотвечено / Несост.)",
        {"x": 0, "y": 4, "w": 24, "h": 8},
        "SELECT\n"
        "  DATE(DATE_SUB(enter_ts, INTERVAL WEEKDAY(enter_ts) DAY)) AS time,\n"
        "  COUNT(*)                                                      AS `Получено`,\n"
        "  SUM(disposition='ANSWERED')                                   AS `Отвечено`,\n"
        "  SUM(disposition='ABANDON')                                    AS `Неотвечено`,\n"
        "  SUM(disposition IN ('ABANDON','EXITWITHTIMEOUT','EXITEMPTY')) AS `Несостоявшийся`\n"
        f"FROM queue_calls WHERE {WHERE_QA}\n"
        "GROUP BY time ORDER BY time"))

    # Ряд 3 — по часам
    p.append(bar_panel(20, "Нагрузка по часам дня",
        {"x": 0, "y": 12, "w": 12, "h": 8},
        "SELECT\n"
        "  HOUR(enter_ts) AS `Час`,\n"
        "  COUNT(*)                                                      AS `Получено`,\n"
        "  SUM(disposition='ANSWERED')                                   AS `Отвечено`,\n"
        "  SUM(disposition='ABANDON')                                    AS `Неотвечено`,\n"
        "  SUM(disposition IN ('ABANDON','EXITWITHTIMEOUT','EXITEMPTY')) AS `Несостоявшийся`\n"
        f"FROM queue_calls WHERE {WHERE_QA}\n"
        "GROUP BY `Час` ORDER BY `Час`",
        x_field="Час"))
    p.append(bar_panel(21, "Среднее ожидание/разговор по часам (сек)",
        {"x": 12, "y": 12, "w": 12, "h": 8},
        "SELECT\n"
        "  HOUR(enter_ts) AS `Час`,\n"
        "  ROUND(AVG(TIMESTAMPDIFF(SECOND, enter_ts, connect_ts)),1) AS `Ср. ожидание`,\n"
        "  ROUND(AVG(TIMESTAMPDIFF(SECOND, connect_ts, end_ts)),1)   AS `Ср. разговор`\n"
        f"FROM queue_calls WHERE {WHERE_QA}\n"
        "  AND disposition='ANSWERED' AND end_ts IS NOT NULL\n"
        "GROUP BY `Час` ORDER BY `Час`",
        x_field="Час"))

    # Ряд 4 — по дням недели
    p.append(bar_panel(30, "Нагрузка по дням недели",
        {"x": 0, "y": 20, "w": 12, "h": 8},
        "SELECT\n"
        "  CASE DAYOFWEEK(enter_ts)\n"
        "    WHEN 2 THEN '1 Пн' WHEN 3 THEN '2 Вт' WHEN 4 THEN '3 Ср'\n"
        "    WHEN 5 THEN '4 Чт' WHEN 6 THEN '5 Пт' WHEN 7 THEN '6 Сб'\n"
        "    WHEN 1 THEN '7 Вс' END AS `День`,\n"
        "  COUNT(*)                                                      AS `Получено`,\n"
        "  SUM(disposition='ANSWERED')                                   AS `Отвечено`,\n"
        "  SUM(disposition='ABANDON')                                    AS `Неотвечено`,\n"
        "  SUM(disposition IN ('ABANDON','EXITWITHTIMEOUT','EXITEMPTY')) AS `Несостоявшийся`\n"
        f"FROM queue_calls WHERE {WHERE_QA}\n"
        "GROUP BY `День` ORDER BY `День`",
        x_field="День"))
    p.append(table_panel(31, "KPI по дням недели",
        {"x": 12, "y": 20, "w": 12, "h": 8},
        "SELECT\n"
        "  CASE DAYOFWEEK(enter_ts)\n"
        "    WHEN 2 THEN 'Пн' WHEN 3 THEN 'Вт' WHEN 4 THEN 'Ср'\n"
        "    WHEN 5 THEN 'Чт' WHEN 6 THEN 'Пт' WHEN 7 THEN 'Сб'\n"
        "    WHEN 1 THEN 'Вс' END AS `День`,\n"
        "  COUNT(*)                                                     AS `Получено`,\n"
        "  SUM(disposition='ANSWERED')                                  AS `Отвечено`,\n"
        "  SUM(disposition='ABANDON')                                   AS `Неотвечено`,\n"
        "  SUM(disposition IN ('ABANDON','EXITWITHTIMEOUT','EXITEMPTY'))AS `Несост.`,\n"
        "  ROUND(SUM(disposition='ANSWERED')/NULLIF(COUNT(*),0)*100,1)  AS `% Отв`,\n"
        "  ROUND(AVG(CASE WHEN disposition='ANSWERED'\n"
        "             THEN TIMESTAMPDIFF(SECOND, enter_ts, connect_ts) END),1) AS `Ср.ожид (с)`,\n"
        "  ROUND(AVG(CASE WHEN disposition='ANSWERED' AND end_ts IS NOT NULL\n"
        "             THEN TIMESTAMPDIFF(SECOND, connect_ts, end_ts) END),1)   AS `Ср.разг (с)`\n"
        f"FROM queue_calls WHERE {WHERE_QA}\n"
        "GROUP BY DAYOFWEEK(enter_ts) ORDER BY DAYOFWEEK(enter_ts)"))

    # Ряд 5 — по операторам
    p.append(table_panel(40, "Нагрузка по операторам",
        {"x": 0, "y": 28, "w": 24, "h": 12},
        "SELECT\n"
        "  agent AS `Оператор`,\n"
        "  COUNT(*)                                                      AS `Получено`,\n"
        "  SUM(disposition='ANSWERED')                                   AS `Отвечено`,\n"
        "  SUM(disposition='ABANDON')                                    AS `Неотвечено`,\n"
        "  SUM(disposition IN ('ABANDON','EXITWITHTIMEOUT','EXITEMPTY')) AS `Несост.`,\n"
        "  ROUND(SUM(disposition='ANSWERED')/NULLIF(COUNT(*),0)*100,1)   AS `% Отв`,\n"
        "  ROUND(AVG(CASE WHEN disposition='ANSWERED'\n"
        "             THEN TIMESTAMPDIFF(SECOND, enter_ts, connect_ts) END),1) AS `Ср.ожид (с)`,\n"
        "  ROUND(AVG(CASE WHEN disposition='ANSWERED' AND end_ts IS NOT NULL\n"
        "             THEN TIMESTAMPDIFF(SECOND, connect_ts, end_ts) END),1)   AS `Ср.разг (с)`,\n"
        "  ROUND(SUM(CASE WHEN disposition='ANSWERED' AND end_ts IS NOT NULL\n"
        "             THEN TIMESTAMPDIFF(SECOND, connect_ts, end_ts) END)/60,1) AS `Мин разг`,\n"
        "  ROUND(AVG(CASE WHEN disposition='ANSWERED' AND end_ts IS NOT NULL\n"
        "             THEN TIMESTAMPDIFF(SECOND, enter_ts, connect_ts)\n"
        "                + TIMESTAMPDIFF(SECOND, connect_ts, end_ts) END),1)   AS `AHT (с)`\n"
        f"FROM queue_calls WHERE {WHERE_QA} AND agent IS NOT NULL AND agent<>''\n"
        "GROUP BY agent ORDER BY `Отвечено` DESC"))

    return dashboard("callstats-load", "Колл-центр — Нагрузка", p,
                     tags=["callstats", "нагрузка", "отчёт"],
                     time_from="now-30d")


# ============================================================================
# Дашборд 2: Колл-центр — Очереди
# ============================================================================
def build_queues():
    p = []

    p.append(timeseries_panel(1,
        "Предложено / Принято / Брошено / Несостоявшийся (по дням)",
        {"x": 0, "y": 0, "w": 24, "h": 8},
        "SELECT\n"
        "  CAST(CONCAT(day,' 00:00:00') AS DATETIME) AS time,\n"
        "  SUM(offered)       AS offered,\n"
        "  SUM(answered)      AS answered,\n"
        "  SUM(abandoned)     AS abandoned,\n"
        "  SUM(not_completed) AS not_completed\n"
        "FROM queue_daily\n"
        "WHERE $__timeFilter(day) AND queuename LIKE '${queue:raw}'\n"
        "GROUP BY day ORDER BY day"))

    p.append(timeseries_panel(2, "ASA (сек) — взвешенная",
        {"x": 0, "y": 8, "w": 12, "h": 6},
        "SELECT\n"
        "  CAST(CONCAT(day,' 00:00:00') AS DATETIME) AS time,\n"
        "  CASE WHEN SUM(answered)>0\n"
        "       THEN SUM(asa_sec*answered)/SUM(answered) ELSE NULL END AS asa_sec\n"
        "FROM queue_daily\n"
        "WHERE $__timeFilter(day) AND queuename LIKE '${queue:raw}'\n"
        "GROUP BY day ORDER BY day",
        unit="s"))

    p.append(timeseries_panel(3, "Брошенные (%)",
        {"x": 12, "y": 8, "w": 12, "h": 6},
        "SELECT\n"
        "  CAST(CONCAT(day,' 00:00:00') AS DATETIME) AS time,\n"
        "  CASE WHEN SUM(offered)>0\n"
        "       THEN SUM(abandoned)/SUM(offered)*100.0 ELSE NULL END AS abandon_rate\n"
        "FROM queue_daily\n"
        "WHERE $__timeFilter(day) AND queuename LIKE '${queue:raw}'\n"
        "GROUP BY day ORDER BY day",
        unit="percent"))

    p.append(timeseries_panel(4, "SLA 20s / SLA 30s (%)",
        {"x": 0, "y": 14, "w": 24, "h": 6},
        "SELECT\n"
        "  CAST(CONCAT(day,' 00:00:00') AS DATETIME) AS time,\n"
        "  CASE WHEN SUM(answered)>0\n"
        "       THEN SUM(sla_20_pct*answered)/SUM(answered) ELSE NULL END AS sla20,\n"
        "  CASE WHEN SUM(answered)>0\n"
        "       THEN SUM(sla_30_pct*answered)/SUM(answered) ELSE NULL END AS sla30\n"
        "FROM queue_daily\n"
        "WHERE $__timeFilter(day) AND queuename LIKE '${queue:raw}'\n"
        "GROUP BY day ORDER BY day",
        unit="percent"))

    p.append(heatmap_panel(5,
        f"Ожидание ответа: heatmap (15 мин × 5 сек, >{HEATMAP_CAP_SEC}с в верхнюю корзину)",
        {"x": 0, "y": 20, "w": 24, "h": 10},
        heatmap_sql()))

    p.append(table_panel(6, "Топ операторов (за период)",
        {"x": 0, "y": 30, "w": 24, "h": 10},
        "SELECT\n"
        "  agent AS `Оператор`,\n"
        "  COUNT(*)                                                             AS `Принято`,\n"
        "  ROUND(AVG(TIMESTAMPDIFF(SECOND, enter_ts, connect_ts)),2)            AS `Ожидание, сек`,\n"
        "  ROUND(AVG(TIMESTAMPDIFF(SECOND, connect_ts, IFNULL(end_ts, NOW()))),2) AS `Разговор, сек`,\n"
        "  ROUND(SUM(TIMESTAMPDIFF(SECOND, connect_ts, IFNULL(end_ts, NOW())))/60,2) AS `Разговор, мин`\n"
        "FROM queue_calls\n"
        "WHERE $__timeFilter(enter_ts) AND disposition='ANSWERED'\n"
        "  AND queuename LIKE '${queue:raw}'\n"
        "  AND agent IS NOT NULL AND agent<>''\n"
        "  AND agent LIKE '${agent:raw}'\n"
        "GROUP BY agent ORDER BY `Принято` DESC"))

    return dashboard("callstats-queues", "Колл-центр — Очереди", p,
                     tags=["callstats", "очереди"])


# ============================================================================
# Дашборд 3: Колл-центр — Оператор
# ============================================================================
def build_agent():
    p = []

    p.append(stat_panel(1, "Принято звонков (ANSWERED)",
        {"x": 0, "y": 0, "w": 6, "h": 4},
        "SELECT COUNT(*) AS value FROM queue_calls "
        f"WHERE {WHERE_QA} AND disposition='ANSWERED'"))
    p.append(stat_panel(2, "Среднее ожидание (сек)",
        {"x": 6, "y": 0, "w": 6, "h": 4},
        "SELECT ROUND(AVG(TIMESTAMPDIFF(SECOND, enter_ts, connect_ts)),2) AS value "
        f"FROM queue_calls WHERE {WHERE_QA} AND disposition='ANSWERED'",
        unit="s"))
    p.append(stat_panel(3, "SLA 20 сек (%) по ANSWERED",
        {"x": 12, "y": 0, "w": 3, "h": 4},
        "SELECT ROUND(100.0*SUM(TIMESTAMPDIFF(SECOND, enter_ts, connect_ts)<=20)"
        "/NULLIF(COUNT(*),0),1) AS value "
        f"FROM queue_calls WHERE {WHERE_QA} AND disposition='ANSWERED'",
        unit="percent"))
    p.append(stat_panel(4, "SLA 30 сек (%) по ANSWERED",
        {"x": 15, "y": 0, "w": 3, "h": 4},
        "SELECT ROUND(100.0*SUM(TIMESTAMPDIFF(SECOND, enter_ts, connect_ts)<=30)"
        "/NULLIF(COUNT(*),0),1) AS value "
        f"FROM queue_calls WHERE {WHERE_QA} AND disposition='ANSWERED'",
        unit="percent"))
    p.append(stat_panel(7, "Несостоявшийся (ABANDON+TIMEOUT+EMPTY)",
        {"x": 18, "y": 0, "w": 6, "h": 4},
        "SELECT COUNT(*) AS value FROM queue_calls "
        "WHERE $__timeFilter(enter_ts) "
        "AND disposition IN ('ABANDON','EXITWITHTIMEOUT','EXITEMPTY') "
        "AND queuename LIKE '${queue:raw}'"))

    p.append(timeseries_panel(5, "Принято звонков (по дням)",
        {"x": 0, "y": 4, "w": 24, "h": 8},
        "SELECT\n"
        "  CAST(CONCAT(day,' 00:00:00') AS DATETIME) AS time,\n"
        "  SUM(answered) AS answered\n"
        "FROM queue_daily\n"
        "WHERE $__timeFilter(day) AND queuename LIKE '${queue:raw}'\n"
        "GROUP BY day ORDER BY day"))

    p.append(heatmap_panel(6,
        f"Ожидание ответа: heatmap (15 мин × 5 сек, >{HEATMAP_CAP_SEC}с в верхнюю корзину)",
        {"x": 0, "y": 12, "w": 24, "h": 10},
        heatmap_sql()))

    return dashboard("callstats-agent", "Колл-центр — Оператор", p,
                     tags=["callstats", "операторы"])


# ============================================================================
# main
# ============================================================================
def main():
    out_dir = pathlib.Path(sys.argv[1] if len(sys.argv) > 1
                           else "../grafana/dashboards")
    out_dir = out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    for dash in (build_load(), build_queues(), build_agent()):
        path = out_dir / f"{dash['uid']}.json"
        path.write_text(json.dumps(dash, ensure_ascii=False, indent=2),
                        encoding="utf-8")
        print(f"wrote {path} — {len(dash['panels'])} panels")


if __name__ == "__main__":
    main()
