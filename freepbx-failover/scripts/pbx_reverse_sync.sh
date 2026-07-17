#!/bin/bash
export HOME=/root
##############################################
### КОНФИГУРАЦИЯ
##############################################
VIP_IP="172.19.3.202"
MASTER_IP="$VIP_IP"        # куда пушим данные обратно
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
FWCONSOLE_BIN="/usr/sbin/fwconsole"
DBUSER="root"
DBPASS="CHANGE_ME_DB_PASSWORD"
DBNAME_CDR="asteriskcdrdb"
DBNAME_CFG="asterisk"
LOGFILE="/var/log/pbx_reverse_sync.log"
LOCKFILE="/var/run/pbx_reverse_sync.lock"
BOT_TOKEN="CHANGE_ME_TELEGRAM_BOT_TOKEN"
GROUP_CHAT_ID="CHANGE_ME_TELEGRAM_CHAT_ID"
SSH_OPTS="-i /root/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts -o BatchMode=yes -o ConnectTimeout=10"
##############################################
### ФУНКЦИИ
##############################################
log() {
    echo "$("$DATE_BIN" '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}
notify_error() {
    local TEXT="$1"
    echo "$("$DATE_BIN" '+%Y-%m-%d %H:%M:%S') ERROR: $TEXT" >> "$LOGFILE"
    "$CURL_BIN" -s --max-time 10 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${GROUP_CHAT_ID}" \
        --data-urlencode "text=❗ ${TEXT}" >/dev/null 2>&1
}
ssh_remote() {
    "$SSH_BIN" ${SSH_OPTS} root@"${MASTER_IP}" "$@"
}
##############################################
### ПРОВЕРКА VIP
##############################################
if "$IP_BIN" -4 addr show "$LOCAL_IFACE" | grep -q " ${VIP_IP}/"; then
    log "Reverse SYNC: VIP активен на этом хосте -> работаем как новый мастер"
else
    log "Reverse SYNC: VIP НЕ активен -> exit"
    exit 0
fi
##############################################
### LOCK
##############################################
if [ -f "$LOCKFILE" ]; then
    if "$KILL_BIN" -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        notify_error "Reverse SYNC ERROR: уже запущен (PID $(cat $LOCKFILE))"
        exit 1
    else
        echo $$ > "$LOCKFILE"
    fi
else
    echo $$ > "$LOCKFILE"
fi
##############################################
### СТАРТ
##############################################
log "----------------------------------------"
log "PBX REVERSE SYNC start (LOCAL AS MASTER, PUSH to ${MASTER_IP})"
##############################################
### 1. ПРОВЕРКА SSH
##############################################
ssh_remote "echo ok" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    notify_error "Reverse SYNC ERROR: SSH недоступен (${MASTER_IP})"
    rm -f "$LOCKFILE"
    exit 1
fi
##############################################
### 2. SYNC FREEPBX CONFIG (DB)
##############################################
log "Sync FreePBX CONFIG"
TABLES=$("$MYSQL_BIN" -N -u"$DBUSER" -p"$DBPASS" -e "SHOW TABLES IN ${DBNAME_CFG};" 2>>"$LOGFILE")
if [ -z "$TABLES" ]; then
    notify_error "Reverse SYNC ERROR: cannot read local DB"
    rm -f "$LOCKFILE"
    exit 1
fi
CHANGED=0
for T in $TABLES; do
    case "$T" in
        modules|freepbx_settings|admin|cronmanager|kvstore)
            log "Skip table $T"
            continue
        ;;
    esac
    log "Push table $T"
    # TRUNCATE на удалённой стороне перед пушем
    ssh_remote "$MYSQL_BIN -u$DBUSER -p'${DBPASS}' -e 'TRUNCATE TABLE ${DBNAME_CFG}.${T};'" 2>>"$LOGFILE"
    TRUNC_RC=$?
    if [ "$TRUNC_RC" -ne 0 ]; then
        notify_error "Reverse SYNC ERROR: remote TRUNCATE table $T failed"
        continue
    fi
    "$MYSQLDUMP_BIN" -u"$DBUSER" -p"$DBPASS" --single-transaction --quick \
        --no-create-db --no-create-info --skip-triggers --skip-add-drop-table \
        --skip-add-locks --skip-comments \
        "${DBNAME_CFG}" "${T}" \
        | ssh_remote "$MYSQL_BIN -u$DBUSER -p'${DBPASS}' ${DBNAME_CFG}"
    DUMP_RC=${PIPESTATUS[0]:-0}
    IMPORT_RC=${PIPESTATUS[1]:-0}
    if [ "$DUMP_RC" -ne 0 ] || [ "$IMPORT_RC" -ne 0 ]; then
        notify_error "Reverse SYNC ERROR: table $T failed (dump=$DUMP_RC import=$IMPORT_RC)"
    else
        CHANGED=1
    fi
done
##############################################
### 3. SYNC CUSTOM SOUNDS
##############################################
log "Sync custom sounds"
"$RSYNC_BIN" -az --delete \
    /var/lib/asterisk/sounds/ru/custom/ \
    -e "$SSH_BIN ${SSH_OPTS}" \
    root@"${MASTER_IP}":/var/lib/asterisk/sounds/ru/custom/ >> "$LOGFILE" 2>&1
RS=$?
if [ "$RS" -ne 0 ] && [ "$RS" -ne 24 ]; then
    notify_error "Reverse SYNC ERROR: sound sync failed (rc=$RS)"
fi
##############################################
### 4. SYNC CDR
##############################################
log "Sync CDR"
"$MYSQLDUMP_BIN" -u"$DBUSER" -p"$DBPASS" --single-transaction --quick \
    "${DBNAME_CDR}" cdr \
    | ssh_remote "$MYSQL_BIN -u$DBUSER -p'${DBPASS}' ${DBNAME_CDR}"
DUMP_RC=${PIPESTATUS[0]:-0}
IMPORT_RC=${PIPESTATUS[1]:-0}
if [ "$DUMP_RC" -ne 0 ] || [ "$IMPORT_RC" -ne 0 ]; then
    notify_error "Reverse SYNC ERROR: CDR (dump=$DUMP_RC import=$IMPORT_RC)"
fi
##############################################
### 5. SYNC CEL
##############################################
log "Sync CEL"
"$MYSQLDUMP_BIN" -u"$DBUSER" -p"$DBPASS" --single-transaction --quick \
    "${DBNAME_CDR}" cel \
    | ssh_remote "$MYSQL_BIN -u$DBUSER -p'${DBPASS}' ${DBNAME_CDR}"
DUMP_RC=${PIPESTATUS[0]:-0}
IMPORT_RC=${PIPESTATUS[1]:-0}
if [ "$DUMP_RC" -ne 0 ] || [ "$IMPORT_RC" -ne 0 ]; then
    notify_error "Reverse SYNC ERROR: CEL (dump=$DUMP_RC import=$IMPORT_RC)"
fi
##############################################
### 6. SYNC MONITOR (WAV)
##############################################
log "Sync monitor WAV"
"$RSYNC_BIN" -az --ignore-existing \
    /var/spool/asterisk/monitor/ \
    -e "$SSH_BIN ${SSH_OPTS}" \
    root@"${MASTER_IP}":/var/spool/asterisk/monitor/ >> "$LOGFILE" 2>&1
RS=$?
if [ "$RS" -eq 0 ] || [ "$RS" -eq 24 ]; then
    log "Monitor reverse sync OK (rc=$RS)"
else
    notify_error "Reverse SYNC ERROR: rsync monitor (rc=$RS)"
fi
##############################################
### 7. УДАЛЁННЫЙ FWCONSOLE RELOAD
##############################################
if [ "$CHANGED" -eq 1 ]; then
    log "Remote FreePBX reload on ${MASTER_IP}"
    RELOAD_OUT=$(ssh_remote "$FWCONSOLE_BIN reload" 2>&1)
    RELOAD_RC=$?
    echo "$RELOAD_OUT" >> "$LOGFILE"
    if [ "$RELOAD_RC" -eq 0 ]; then
        log "Remote fwconsole reload OK"
    else
        notify_error "Reverse SYNC ERROR: remote fwconsole reload failed (rc=$RELOAD_RC)"
    fi
else
    log "No table changes succeeded - skip remote reload"
fi
##############################################
### КОНЕЦ
##############################################
log "PBX REVERSE SYNC finished"
rm -f "$LOCKFILE"
exit 0
