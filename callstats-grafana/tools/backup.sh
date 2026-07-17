#!/usr/bin/env bash
# =============================================================================
# callstats-grafana / tools / backup.sh
#
# Создаёт golden-бэкап Grafana-инсталляции: дашборды + provisioning + compose.
# Кладёт всё в /opt/grafana/backup_GOLDEN_YYYY-MM-DD_HHMM/ и считает sha256.
#
# Использование:
#   sudo tools/backup.sh
# =============================================================================

set -Eeuo pipefail

GRAFANA_ROOT="${GRAFANA_ROOT:-/opt/grafana}"

if [[ $EUID -ne 0 ]]; then
  echo "Запусти через sudo" >&2
  exit 1
fi

TS="$(date +%F_%H%M)"
GOLDEN="${GRAFANA_ROOT}/backup_GOLDEN_${TS}"

echo "=> Создаю ${GOLDEN}"
mkdir -p "$GOLDEN"

cp -a "${GRAFANA_ROOT}/dashboards"         "$GOLDEN/"
cp -a "${GRAFANA_ROOT}/provisioning"       "$GOLDEN/"
cp -a "${GRAFANA_ROOT}/docker-compose.yml" "$GOLDEN/"

# Контрольные суммы
( cd "$GOLDEN" && sha256sum dashboards/*.json > SHA256SUMS.txt )

cat > "${GOLDEN}/README.txt" <<EOF
GOLDEN BACKUP $(date --iso-8601=seconds)
Host: $(hostname)
Grafana root: ${GRAFANA_ROOT}

DEPLOY (восстановить эту версию):
  sudo cp -a "${GOLDEN}/dashboards/."   ${GRAFANA_ROOT}/dashboards/
  sudo cp -a "${GOLDEN}/provisioning/." ${GRAFANA_ROOT}/provisioning/
  sudo cp -a "${GOLDEN}/docker-compose.yml" ${GRAFANA_ROOT}/
  sudo docker restart grafana

VERIFY:
  for f in ${GRAFANA_ROOT}/dashboards/callstats-*.json; do
    jq . "\$f" >/dev/null && echo "\$f OK" || echo "\$f BROKEN"
  done
EOF

echo "=> Готово"
ls -la "$GOLDEN"
