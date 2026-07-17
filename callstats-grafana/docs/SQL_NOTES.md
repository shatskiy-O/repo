# Особенности SQL под Grafana 12.x

Собрано опытным путём. Все запросы в `tools/build_dashboards.py` уже учитывают эти нюансы.

## 1. Тип столбца `time` строго DATETIME

Grafana 12.x строже проверяет тип. Если запрос возвращает `time` как `VARCHAR`, панель падает с 500:

```
converting time columns failed: failed to convert time column: unable to convert data to a time field
```

**Плохо:**

```sql
SELECT CONCAT(day, ' 00:00:00') AS time, ...
```

**Хорошо:**

```sql
SELECT CAST(CONCAT(day, ' 00:00:00') AS DATETIME) AS time, ...
```

## 2. Формат переменных

Использовать `:raw`, не `:sqlstring`:

```sql
WHERE queuename LIKE '${queue:raw}'
```

Переменная должна быть определена как:

```json
{
  "multi": false,
  "includeAll": true,
  "allValue": "%",
  "current": {"text": "Все", "value": "$__all"}
}
```

При выборе `All` подставляется `%`, при выборе конкретного значения — оно само. LIKE это одинаково жуёт.

`sqlstring` ломается: превращает `605` в `'605'`, а вокруг него SQL добавляет ещё пару кавычек — получается синтаксическая ошибка.

`CONCAT('%','$queue','%')` тоже ломается: выражение `$queue` внутри строкового литерала MySQL не подставляется на уровне Grafana, ему нужен либо `${queue:raw}` вне литерала, либо `${queue:sqlstring}` без ручного добавления кавычек.

## 3. Timeseries формат кадра

Для `format: "time_series"` первое поле = `time` (DATETIME), остальные = числовые метрики. Grafana сама превратит их в отдельные серии.

```sql
SELECT
  CAST(CONCAT(day, ' 00:00:00') AS DATETIME) AS time,
  SUM(offered)   AS offered,
  SUM(answered) AS answered
FROM queue_daily
WHERE $__timeFilter(day)
GROUP BY day ORDER BY day
```

Даст две серии: `offered` и `answered`.

## 4. Table формат

Для `format: "table"` порядок и типы полей произвольные. Первое поле НЕ обязано быть `time`. Панель `barchart` умеет использовать любое поле как X-ось через `options.xField`.

```json
"xField": "Час",
"orientation": "vertical"
```

## 5. Heatmap с precomputed бакетами

Grafana умеет два режима:

- **calculate=true**: сама раскладывает `value` по бакетам.
- **calculate=false**: строки, где каждая `metric` — своя корзина на оси Y.

Для наших нужд второй вариант удобнее (кастомные бакеты). Формат запроса:

```sql
SELECT
  time,     -- DATETIME
  metric,   -- строка-имя бакета
  value     -- число (счётчик)
FROM ...
GROUP BY time, metric
ORDER BY time, metric
```

Важно: `metric`-строки сортируются лексикографически. Для правильной сортировки на оси Y:
- одинаковая длина (`LPAD(..., 5, '0')`);
- верхний бакет-выброс — символ, сортирующийся после цифр (`'>120'` вместо `'120+'`).

## 6. `$__timeFilter(column)` — макрос Grafana

Grafana подставляет условие фильтра по выбранному в дашборде диапазону:

```sql
WHERE $__timeFilter(enter_ts)
-- превращается в:
-- WHERE enter_ts BETWEEN FROM_UNIXTIME(1747044180) AND FROM_UNIXTIME(1747058580)
```

Работает и с DATE-столбцами (`$__timeFilter(day)`).

## 7. Что НЕ работает или капризно

- `$__timeGroupAlias(column, interval)` — на MariaDB иногда рендерится с ошибкой. Замена: ручной FROM_UNIXTIME + FLOOR:

  ```sql
  FROM_UNIXTIME(FLOOR(UNIX_TIMESTAMP(enter_ts)/900)*900) AS time
  ```

- `MEDIAN()` — MariaDB не поддерживает. Приближение через оконки:

  ```sql
  SELECT AVG(wait) FROM (
    SELECT wait, ROW_NUMBER() OVER (ORDER BY wait) rn, COUNT(*) OVER () cnt
    FROM ...
  ) t WHERE rn IN (FLOOR((cnt+1)/2), CEIL((cnt+1)/2))
  ```

- SET `sql_mode = 'ONLY_FULL_GROUP_BY'` — на некоторых FreePBX включён по умолчанию. Наши SQL сгруппированы полностью, но если добавлять новые — проверять, что все не-агрегатные поля есть в GROUP BY.

## 8. Производительность

Основные тяжёлые панели — heatmap и таблица операторов. Они читают всю `queue_calls` за период фильтра.

**Индексы (уже в схеме):**

- `KEY (enter_ts)`
- `KEY (queuename, enter_ts)`
- `KEY (agent, enter_ts)`

При окне 30 дней и 200k строк запрос отрабатывает < 500ms. При окне 1 год стоит подумать о пред-агрегатах на уровне часа (`queue_hourly`).

## 9. Обработка пропусков в тайминге

Некоторые звонки в `queue_calls` имеют `connect_ts IS NULL` (не соединились) или `end_ts IS NULL` (ещё в моменте). Все `TIMESTAMPDIFF` в панелях обёрнуты в CASE:

```sql
CASE WHEN disposition='ANSWERED' AND end_ts IS NOT NULL
  THEN TIMESTAMPDIFF(SECOND, connect_ts, end_ts)
END
```

AVG над таким CASE игнорирует NULL — что и нужно.
