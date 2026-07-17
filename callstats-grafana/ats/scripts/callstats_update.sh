#!/usr/bin/env bash
# =============================================================================
# callstats-grafana / АТС / callstats_update.sh
#
# Обёртка над callstats_rebuild_2d.sql. Запускается по cron каждые 5 минут.
# Пароль writer'а читает из /root/.callstats_db.conf (chmod 600, вне git).
#
# Устанавливается на АТС в /usr/local/bin/callstats_update.sh
# =============================================================================

set -Eeuo pipefail

CONF="/root/.callstats_db.conf"
SQL="/usr/local/bin/callstats_rebuild_2d.sql"
LOG="/var/log/callstats_update.log"

TS() { date '+[%F %T]'; }

if [[ ! -r "$CONF" ]]; then
  echo "$(TS) callstats_update: FATAL — конфиг $CONF недоступен" >>"$LOG"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONF"
: "${CALLSTATS_DB_PASS:?CALLSTATS_DB_PASS не задан в $CONF}"

echo "$(TS) callstats_update: start" >>"$LOG"

mysql --defaults-extra-file=<(cat <<EOF
[client]
user=callstats_writer
password=${CALLSTATS_DB_PASS}
host=127.0.0.1
port=3306
EOF
) callstats < "$SQL" 2>>"$LOG"

echo "$(TS) callstats_update: done" >>"$LOG"
