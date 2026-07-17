#!/bin/bash
export HOME=/root
##############################################
### КОНФИГУРАЦИЯ
##############################################
MASTER_IP="172.19.3.202"
VIP_IP="172.19.3.202"
LOCAL_IFACE="eth0"
IP_BIN="/sbin/ip"
SSH_BIN="/usr/bin/ssh"
MYSQL_BIN="/usr/bin/mysql"
MYSQLDUMP_BIN="/usr/bin/mysqldump"
RSYNC_BIN="/usr/bin/rsync"
CURL_BIN="/usr/bin/curl"
DATE_BIN="/bin/date"
MKDIR_BIN="/bin/mkdir"
TOUCH_BIN="/bin/touch"
CHMOD_BIN="/bin/chmod"
KILL_BIN="/bin/kill"
DBUSER="root"
DBPASS="CHANGE_ME_DB_PASSWORD"
DBNAME="asteriskcdrdb"
LOGFILE="/var/log/pbx_sync.log"
LOCKFILE="/var/run/sync_from_202.lock"
DAYS=7
BOT_TOKEN="CHANGE_ME_TELEGRAM_BOT_TOKEN"
GROUP_CHAT_ID="CHANGE_ME_TELEGRAM_CHAT_ID"
SSH_OPTS="-i /root/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts -o BatchMode=yes -o ConnectTimeout=10"
##############################################
### ФУНКЦИИ
##############################################
log() {
    echo "$("$DATE_BIN" '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOGFILE"
}
notify() {
    local TEXT="$1"
    echo "$("$DATE_BIN" '+%Y-%m-%d %H:%M:%S')  $TEXT" >> "$LOGFILE"
    "$CURL_BIN" -s --max-time 10 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${GROUP_CHAT_ID}" \
        --data-urlencode "text=${TEXT}" >/dev/null 2>&1
}
ssh_master() {
    "$SSH_BIN" ${SSH_OPTS} root@"${MASTER_IP}" "$@"
}
##############################################
### ОПРЕДЕЛЕНИЕ РОЛИ УЗЛА
##############################################
LOCAL_IP=$("$IP_BIN" -4 addr show "$LOCAL_IFACE" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
if "$IP_BIN" -4 addr show "$LOCAL_IFACE" | grep -q " ${VIP_IP}/"; then
    log "PBX SYNC: VIP ${VIP_IP} активен локально -> этот узел MASTER -> exit"
    exit 0
fi
if [ "$LOCAL_IP" = "$MASTER_IP" ]; then
    log "PBX SYNC: LOCAL_IP=$LOCAL_IP совпадает с MASTER -> exit"
    exit 0
fi
##############################################
### LOCK
##############################################
if [ -f "$LOCKFILE" ]; then
    if "$KILL_BIN" -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        notify "PBX SYNC ERROR: previous sync still running (PID $(cat $LOCKFILE))"
        exit 1
    else
        echo $$ > "$LOCKFILE"
    fi
else
    echo $$ > "$LOCKFILE"
fi
##############################################
### ПОДГОТОВКА SSH
##############################################
"$MKDIR_BIN" -p /root/.ssh
"$CHMOD_BIN" 700 /root/.ssh
"$TOUCH_BIN" /root/.ssh/known_hosts
"$CHMOD_BIN" 600 /root/.ssh/known_hosts
##############################################
### СТАРТ
##############################################
log "----------------------------------------"
log "PBX SYNC start (MASTER=${MASTER_IP}, LOCAL=${LOCAL_IP})"
##############################################
### 1. ПРОВЕРКА SSH
##############################################
ssh_master "echo ok" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    notify "PBX SYNC ERROR: SSH недоступен (${MASTER_IP})"
    rm -f "$LOCKFILE"
    exit 1
fi
##############################################
### 2. TIMESTAMP CDR/CEL
##############################################
LAST_CDR_TS=$("$MYSQL_BIN" -N -u"$DBUSER" -p"$DBPASS" -e \
"SELECT DATE_FORMAT(IFNULL(MAX(calldate), NOW() - INTERVAL ${DAYS} DAY),'%Y-%m-%d %H:%i:%s') FROM ${DBNAME}.cdr;" 2>>"$LOGFILE")
LAST_CEL_TS=$("$MYSQL_BIN" -N -u"$DBUSER" -p"$DBPASS" -e \
"SELECT DATE_FORMAT(IFNULL(MAX(eventtime), NOW() - INTERVAL ${DAYS} DAY),'%Y-%m-%d %H:%i:%s') FROM ${DBNAME}.cel;" 2>>"$LOGFILE")
log "LAST_CDR_TS = ${LAST_CDR_TS}"
log "LAST_CEL_TS = ${LAST_CEL_TS}"
##############################################
### 3. СИНХРОНИЗАЦИЯ CDR
##############################################
log "Sync CDR from ${MASTER_IP}"
ssh_master \
"$MYSQLDUMP_BIN -uroot -p'${DBPASS}' --single-transaction --quick \
 --no-create-db --no-create-info --skip-triggers --skip-add-drop-table --skip-add-locks \
 ${DBNAME} cdr --where=\"calldate > '${LAST_CDR_TS}'\" " \
| "$MYSQL_BIN" -u"$DBUSER" -p"$DBPASS" "$DBNAME"
DUMP_RC=${PIPESTATUS[0]:-0}
IMPORT_RC=${PIPESTATUS[1]:-0}
if [ "$DUMP_RC" -ne 0 ] || [ "$IMPORT_RC" -ne 0 ]; then
    notify "PBX SYNC ERROR: CDR sync failed (dump=$DUMP_RC import=$IMPORT_RC)"
else
    log "CDR sync OK"
fi
##############################################
### 4. СИНХРОНИЗАЦИЯ CEL
##############################################
log "Sync CEL from ${MASTER_IP}"
ssh_master \
"$MYSQLDUMP_BIN -uroot -p'${DBPASS}' --single-transaction --quick \
 --no-create-db --no-create-info --skip-triggers --skip-add-drop-table --skip-add-locks \
 ${DBNAME} cel --where=\"eventtime > '${LAST_CEL_TS}'\" " \
| "$MYSQL_BIN" -u"$DBUSER" -p"$DBPASS" "$DBNAME"
DUMP_RC=${PIPESTATUS[0]:-0}
IMPORT_RC=${PIPESTATUS[1]:-0}
if [ "$DUMP_RC" -ne 0 ] || [ "$IMPORT_RC" -ne 0 ]; then
    notify "PBX SYNC ERROR: CEL sync failed (dump=$DUMP_RC import=$IMPORT_RC)"
else
    log "CEL sync OK"
fi
##############################################
### 5. RSYNC MONITOR
##############################################
log "Sync monitor files from ${MASTER_IP}"
"$RSYNC_BIN" -az --ignore-existing \
    -e "$SSH_BIN ${SSH_OPTS}" \
    root@"${MASTER_IP}":/var/spool/asterisk/monitor/ \
    /var/spool/asterisk/monitor/ >> "$LOGFILE" 2>&1
RSYNC_RC=$?
if [ "$RSYNC_RC" -eq 0 ] || [ "$RSYNC_RC" -eq 24 ]; then
    log "Monitor sync OK (rsync rc=$RSYNC_RC)"
else
    notify "PBX SYNC ERROR: ошибка rsync monitor (rc=$RSYNC_RC)"
fi
##############################################
### КОНЕЦ
##############################################
log "PBX SYNC finished"
rm -f "$LOCKFILE"
exit 0
