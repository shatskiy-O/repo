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
FWCONSOLE_BIN="/usr/sbin/fwconsole"
DBUSER="root"
DBPASS="CHANGE_ME_DB_PASSWORD"
DBNAME="asterisk"
LOGFILE="/var/log/pbx_sync_config.log"
LOCKFILE="/var/run/sync_freepbx_config.lock"
BOT_TOKEN="CHANGE_ME_TELEGRAM_BOT_TOKEN"
GROUP_CHAT_ID="CHANGE_ME_TELEGRAM_CHAT_ID"
SSH_OPTS="-i /root/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts -o BatchMode=yes -o ConnectTimeout=10"
##############################################
### ФУНКЦИИ
##############################################
log() {
    echo "$("$DATE_BIN" '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOGFILE"
}
notify_error() {
    local TEXT="$1"
    echo "$("$DATE_BIN" '+%Y-%m-%d %H:%M:%S') ERROR: $TEXT" >> "$LOGFILE"
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
# Если VIP поднят локально - этот узел сейчас МАСТЕР, синх НЕ нужен
if "$IP_BIN" -4 addr show "$LOCAL_IFACE" | grep -q " ${VIP_IP}/"; then
    log "CONFIG SYNC: VIP ${VIP_IP} активен локально -> этот узел MASTER -> exit"
    exit 0
fi
# Подстраховка: если IP узла совпадает с MASTER_IP
if [ "$LOCAL_IP" = "$MASTER_IP" ]; then
    log "CONFIG SYNC: LOCAL_IP=$LOCAL_IP совпадает с MASTER -> exit"
    exit 0
fi
##############################################
### LOCK
##############################################
if [ -f "$LOCKFILE" ]; then
    if "$KILL_BIN" -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        notify_error "CONFIG SYNC ERROR: previous sync still running (PID $(cat $LOCKFILE))"
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
log "FREEPBX CONFIG SYNC start (MASTER=${MASTER_IP}, LOCAL=${LOCAL_IP})"
##############################################
### 1. ПРОВЕРКА SSH
##############################################
ssh_master "echo ok" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    notify_error "CONFIG SYNC ERROR: SSH недоступен (${MASTER_IP})"
    rm -f "$LOCKFILE"
    exit 1
fi
##############################################
### 2. СПИСОК ТАБЛИЦ
##############################################
TABLES=$("$MYSQL_BIN" -N -u"$DBUSER" -p"$DBPASS" -e "SHOW TABLES IN $DBNAME;" 2>>"$LOGFILE")
if [ $? -ne 0 ] || [ -z "$TABLES" ]; then
    notify_error "CONFIG SYNC ERROR: cannot read local DB"
    rm -f "$LOCKFILE"
    exit 1
fi
##############################################
### 3. ЦИКЛ ПО ТАБЛИЦАМ
##############################################
CHANGED=0
for T in $TABLES; do
    case "$T" in
        modules|freepbx_settings|admin|cronmanager|kvstore)
            log "Skip table $T"
            continue
        ;;
    esac
    log "Sync table $T"
    "$MYSQL_BIN" -u"$DBUSER" -p"$DBPASS" -e "TRUNCATE TABLE $DBNAME.$T;" 2>>"$LOGFILE"
    if [ $? -ne 0 ]; then
        notify_error "CONFIG SYNC ERROR: cannot truncate table $T"
        continue
    fi
    ssh_master \
        "$MYSQLDUMP_BIN -uroot -p'${DBPASS}' --single-transaction --quick \
        --no-create-db --no-create-info --skip-triggers --skip-add-drop-table \
        --skip-add-locks --skip-comments ${DBNAME} ${T}" \
        | "$MYSQL_BIN" -u"$DBUSER" -p"$DBPASS" "$DBNAME"
    DUMP_RC=${PIPESTATUS[0]:-0}
    IMPORT_RC=${PIPESTATUS[1]:-0}
    if [ "$DUMP_RC" -ne 0 ] || [ "$IMPORT_RC" -ne 0 ]; then
        notify_error "CONFIG SYNC ERROR: table $T failed (dump=$DUMP_RC import=$IMPORT_RC)"
    else
        CHANGED=1
    fi
done
##############################################
### 4. CUSTOM SOUNDS
##############################################
log "Sync custom sounds"
"$RSYNC_BIN" -az --delete \
    -e "$SSH_BIN ${SSH_OPTS}" \
    root@"${MASTER_IP}":/var/lib/asterisk/sounds/ru/custom/ \
    /var/lib/asterisk/sounds/ru/custom/ >> "$LOGFILE" 2>&1
RS=$?
# rc=24 - normal for live system (some files vanished during transfer)
if [ "$RS" -ne 0 ] && [ "$RS" -ne 24 ]; then
    notify_error "CONFIG SYNC ERROR: custom sound sync failed (rc=$RS)"
fi
##############################################
### 5. FWCONSOLE RELOAD
##############################################
if [ "$CHANGED" -eq 1 ]; then
    log "FreePBX reload"
    RELOAD_OUT=$("$FWCONSOLE_BIN" reload 2>&1)
    RELOAD_RC=$?
    echo "$RELOAD_OUT" >> "$LOGFILE"
    if [ "$RELOAD_RC" -eq 0 ]; then
        log "fwconsole reload OK"
    else
        notify_error "CONFIG SYNC ERROR: fwconsole reload failed (rc=$RELOAD_RC)"
    fi
else
    log "No table changes succeeded - skip reload"
fi
##############################################
### КОНЕЦ
##############################################
log "FREEPBX CONFIG SYNC completed"
rm -f "$LOCKFILE"
exit 0
