#!/usr/bin/env bash
# =============================================================================
# callstats-grafana / tools / restore.sh
#
# Восстанавливает Grafana из указанного golden-бэкапа.
#
# Использование:
#   sudo tools/restore.sh /opt/grafana/backup_GOLDEN_2026-05-15_1440
# =============================================================================

set -Eeuo pipefail

GRAFANA_ROOT="${GRAFANA_ROOT:-/opt/grafana}"

if [[ $EUID -ne 0 ]]; then
  echo "Запусти через sudo" >&2
  exit 1
fi

BKP="${1:-}"
if [[ -z "$BKP" || ! -d "$BKP" ]]; then
  echo "Usage: sudo $0 <backup_dir>" >&2
  echo "Available backups:" >&2
  ls -1d "${GRAFANA_ROOT}"/backup_GOLDEN_* 2>/dev/null >&2 || echo "  (нет)" >&2
  exit 1
fi

echo "=> Восстанавливаю из $BKP"

# Мини-safety-net: сохраним ТЕКУЩЕЕ состояние прежде чем накатывать бэкап
TS="$(date +%F_%H%M)"
SAFETY="${GRAFANA_ROOT}/backup_before_restore_${TS}"
mkdir -p "$SAFETY"
cp -a "${GRAFANA_ROOT}/dashboards" "${GRAFANA_ROOT}/provisioning" \
      "${GRAFANA_ROOT}/docker-compose.yml" "$SAFETY/" 2>/dev/null || true
echo "=> Текущее состояние сохранено в $SAFETY"

cp -a "$BKP/dashboards/."         "${GRAFANA_ROOT}/dashboards/"
cp -a "$BKP/provisioning/."       "${GRAFANA_ROOT}/provisioning/"
[[ -f "$BKP/docker-compose.yml" ]] && cp -a "$BKP/docker-compose.yml" "${GRAFANA_ROOT}/"

echo "=> Перезапускаю Grafana"
docker restart grafana

sleep 3

echo "=> Валидация JSON"
for f in "${GRAFANA_ROOT}/dashboards/"callstats-*.json; do
  jq . "$f" >/dev/null && echo "  $f OK" || echo "  $f BROKEN"
done

echo "=> Готово"
