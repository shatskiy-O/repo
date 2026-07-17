#!/usr/bin/env bash
# =============================================================================
# callstats-grafana / tools / healthcheck.sh
#
# Быстрая проверка всей цепочки: SSH-туннель → MySQL → Grafana → данные.
# Ничего не меняет. Возвращает 0 если всё ок, 1 если что-то сломано.
#
# Использование:
#   ./tools/healthcheck.sh
#
# Читает параметры из .env рядом со скриптом (или из ../.env).
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"
[[ -r "$ENV_FILE" ]] && source "$ENV_FILE"

: "${GF_LOCAL_TUNNEL_PORT:=3307}"
: "${CALLSTATS_DB:=callstats}"
: "${CALLSTATS_RO_USER:=callstats_ro}"

FAIL=0
ok()   { printf "  \033[32m✓\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m  %s\n" "$1"; FAIL=1; }

echo "1) SSH-туннель"
if ss -lntp 2>/dev/null | grep -q ":${GF_LOCAL_TUNNEL_PORT} "; then
  ok "порт ${GF_LOCAL_TUNNEL_PORT} слушается"
else
  fail "порт ${GF_LOCAL_TUNNEL_PORT} не слушается — проверь systemctl status ats-mysql-tunnel"
fi

echo
echo "2) MariaDB через туннель"
if [[ -n "${CALLSTATS_RO_PASS:-}" ]]; then
  ROWS="$(mysql -h 127.0.0.1 -P "${GF_LOCAL_TUNNEL_PORT}" --protocol=tcp \
    -u "${CALLSTATS_RO_USER}" -p"${CALLSTATS_RO_PASS}" "${CALLSTATS_DB}" \
    -Ns -e "SELECT COUNT(*) FROM queue_daily" 2>/dev/null || echo "")"
  if [[ -n "$ROWS" && "$ROWS" -ge 0 ]]; then
    ok "queue_daily доступна, строк: ${ROWS}"
  else
    fail "не удалось прочитать queue_daily"
  fi
else
  fail "CALLSTATS_RO_PASS не задан (проверь .env)"
fi

echo
echo "3) Свежесть данных"
if [[ -n "${CALLSTATS_RO_PASS:-}" ]]; then
  AGE="$(mysql -h 127.0.0.1 -P "${GF_LOCAL_TUNNEL_PORT}" --protocol=tcp \
    -u "${CALLSTATS_RO_USER}" -p"${CALLSTATS_RO_PASS}" "${CALLSTATS_DB}" \
    -Ns -e "SELECT TIMESTAMPDIFF(MINUTE, MAX(enter_ts), NOW()) FROM queue_calls" 2>/dev/null || echo "")"
  if [[ -n "$AGE" && "$AGE" -le 15 ]]; then
    ok "последний звонок ${AGE} мин назад"
  elif [[ -n "$AGE" ]]; then
    fail "последний звонок ${AGE} мин назад — ETL мог отстать"
  else
    fail "не смог определить свежесть"
  fi
fi

echo
echo "4) Grafana"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx grafana; then
  ok "контейнер grafana запущен"
else
  fail "контейнер grafana не запущен"
fi

if curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:3000/api/health" 2>/dev/null | grep -q 200; then
  ok "http://127.0.0.1:3000/api/health отвечает 200"
else
  fail "Grafana HTTP не отвечает"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "→ Всё в порядке"
  exit 0
else
  echo "→ Есть проблемы, см. выше"
  exit 1
fi
