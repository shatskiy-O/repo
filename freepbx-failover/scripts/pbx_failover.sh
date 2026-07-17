#!/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
MASTER_IP="172.19.3.202"
BACKUP_IP="172.19.3.203"
NETMASK="/24"
IFACE="eth0"
GATEWAY="172.19.3.1"
NODE_NAME="PBX203"
PING_COUNT=3
PING_TIMEOUT=1
FAIL_THRESHOLD=2
STATE_FILE="/var/run/pbx_failover_failcount"
LOGFILE="/var/log/pbx_failover.log"
DATE_BIN="/bin/date"
IP_BIN="/sbin/ip"
CURL_BIN="/usr/bin/curl"
ARPING_BIN="/usr/sbin/arping"
LOGGER_BIN="/usr/bin/logger"
BOT_TOKEN="CHANGE_ME_TELEGRAM_BOT_TOKEN"
CHAT_ID="CHANGE_ME_TELEGRAM_CHAT_ID"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo PBX)"
timestamp() {
    "$DATE_BIN" '+%Y-%m-%d %H:%M:%S'
}
log() {
    local MSG="$1"
    echo "$(timestamp) $MSG" >> "$LOGFILE"
    if [ -x "$LOGGER_BIN" ]; then
        "$LOGGER_BIN" -t pbx_failover "$MSG"
    fi
}
notify() {
    local TEXT="$1"
    "$CURL_BIN" -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${TEXT}" >/dev/null 2>&1
}
check_ssh_alive() {
    if [ -x /usr/bin/nc ]; then
        /usr/bin/nc -z -w 2 "$MASTER_IP" 22 >/dev/null 2>&1
        return $?
    elif [ -x /usr/bin/timeout ]; then
        /usr/bin/timeout 3 bash -c ">/dev/tcp/${MASTER_IP}/22" 2>/dev/null
        return $?
    else
        log "WARN: нет nc/timeout — не могу проверить SSH"
        return 0
    fi
}
###############################################
# Определяем, какие IP уже есть на интерфейсе
###############################################
HAS_MASTER=0
HAS_BACKUP=0
while read -r ipaddr; do
    case "$ipaddr" in
        "$MASTER_IP") HAS_MASTER=1 ;;
        "$BACKUP_IP") HAS_BACKUP=1 ;;
    esac
done < <($IP_BIN -4 addr show "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)
###############################################
# Если на ноде ТОЛЬКО MASTER_IP — это уже MASTER
###############################################
if [ "$HAS_MASTER" -eq 1 ] && [ "$HAS_BACKUP" -eq 0 ]; then
    log "Этот узел уже MASTER — ничего не делаем."
    exit 0
fi
###############################################
# Счётчик ошибок
###############################################
if [ -f "$STATE_FILE" ]; then
    FAIL_COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
else
    FAIL_COUNT=0
fi
###############################################
# Проверяем доступность MASTER
###############################################
if ping -q -c "$PING_COUNT" -W "$PING_TIMEOUT" "$MASTER_IP" >/dev/null 2>&1; then
    if check_ssh_alive; then
        if [ "$FAIL_COUNT" -ne 0 ]; then
            log "MASTER ${MASTER_IP} доступен — сбрасываю счётчик ошибок"
            echo 0 > "$STATE_FILE"
        fi
        exit 0
    else
        log "WARN: MASTER пингуется, но SSH не отвечает"
        echo 0 > "$STATE_FILE"
        exit 0
    fi
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "$FAIL_COUNT" > "$STATE_FILE"
    log "MASTER ${MASTER_IP} недоступен по ping (${FAIL_COUNT}/${FAIL_THRESHOLD})"
    if [ "$FAIL_COUNT" -lt "$FAIL_THRESHOLD" ]; then
        log "Ждём следующую проверку"
        exit 0
    fi
fi
###############################################
# FAILOVER
###############################################
log "MASTER недоступен — выполняем FAILOVER"
# 1. Удаляем BACKUP_IP
if [ "$HAS_BACKUP" -eq 1 ]; then
    $IP_BIN addr del "${BACKUP_IP}${NETMASK}" dev "$IFACE" 2>/dev/null
    log "Удалён BACKUP IP ${BACKUP_IP}${NETMASK}"
fi
# 2. Назначаем MASTER_IP
if [ "$HAS_MASTER" -eq 0 ]; then
    $IP_BIN addr add "${MASTER_IP}${NETMASK}" dev "$IFACE"
    log "Назначен MASTER IP ${MASTER_IP}${NETMASK}"
else
    log "MASTER IP уже был назначен"
fi
###############################################
# 3. ОБЯЗАТЕЛЬНО: восстановление default gateway
###############################################
$IP_BIN route del default 2>/dev/null
$IP_BIN route add default via "$GATEWAY" dev "$IFACE"
log "Default gateway обновлён: ${GATEWAY} через ${IFACE}"
###############################################
# 4. ARP Refresh
###############################################
if [ -x "$ARPING_BIN" ]; then
    $ARPING_BIN -c 2 -A -I "$IFACE" "$MASTER_IP" >/dev/null 2>&1
    $ARPING_BIN -c 2 -U -I "$IFACE" "$MASTER_IP" >/dev/null 2>&1
    log "ARP refresh выполнен"
fi
echo 0 > "$STATE_FILE"
# УВЕДОМЛЕНИЕ О СМЕНЕ РОЛИ
notify "FAILOVER: ${NODE_NAME} ПОЛУЧИЛ РОЛЬ MASTER. Назначен IP ${MASTER_IP}. Gateway ${GATEWAY}."
exit 0
