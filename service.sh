#!/system/bin/sh

MODDIR=${0%/*}
LOGFILE="$MODDIR/zram_opt.log"
STATEFILE="$MODDIR/last_recomp"

INTERVAL=300                 # 每 5 分钟检查一次
BACKOFF_MINUTES=30           # 至少 30 分钟间隔
COLD_THRESHOLD=30            # 冷页 anon 占比 >=30% 才触发

IDLE_MIN_SECONDS=$((2*3600)) # 2 小时 ~ 4 小时窗口
IDLE_MAX_SECONDS=$((4*3600))
THRESHOLD_BYTES=1024

log() {
    echo "$(date '+%F %T')  $*" >> "$LOGFILE"
}

get_cold_ratio() {
    local DEBUG total=0 cold=0 gen anon
    DEBUG="$(cat /sys/kernel/mm/lru_gen/debug 2>/dev/null)" || { echo 0; return; }

    echo "$DEBUG" | while read -r line; do
        case "$line" in
            "generation "*)
                gen=$(echo "$line" | awk '{print $2}' | tr -d ':')
                ;;
            *"anon="*)
                anon=$(echo "$line" | sed -n 's/.*anon=\([0-9]*\).*/\1/p')
                [ -z "$anon" ] && continue
                total=$((total + anon))
                [ "$gen" -ge 3 ] && cold=$((cold + anon))
                ;;
        esac
    done

    [ "$total" -eq 0 ] && echo 0 || echo $((100 * cold / total))
}

get_psi() {
    grep some /proc/pressure/memory 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i ~ /^avg10=/){split($i,a,"="); print a[2]}}'
}

get_load() {
    awk '{print $1}' /proc/loadavg
}

check_backoff() {
    [ ! -f "$STATEFILE" ] && return 0
    local last now diff
    last=$(cat "$STATEFILE" 2>/dev/null)
    now=$(date +%s)
    diff=$((now - last))
    [ "$diff" -lt $((BACKOFF_MINUTES*60)) ] && return 1 || return 0
}

trigger_recompress() {
    log "trigger zram idle+recompress"
    echo "$IDLE_MIN_SECONDS $IDLE_MAX_SECONDS" > /sys/block/zram0/idle 2>/dev/null

    if [ "$THRESHOLD_BYTES" -gt 0 ]; then
        echo "type=huge_idle threshold=$THRESHOLD_BYTES" > /sys/block/zram0/recompress 2>/dev/null
        echo "type=idle threshold=$THRESHOLD_BYTES"      > /sys/block/zram0/recompress 2>/dev/null
    else
        echo "type=huge_idle" > /sys/block/zram0/recompress 2>/dev/null
        echo "type=idle"      > /sys/block/zram0/recompress 2>/dev/null
    fi

    date +%s > "$STATEFILE"
}

# ==================== main loop ====================
while true; do
    [ ! -e /sys/block/zram0/recompress ] && log "device not support recompress" && exit 1

    PSI=$(get_psi)
    LOAD=$(get_load)
    COLD=$(get_cold_ratio)

    log "PSI=$PSI LOAD=$LOAD COLD=${COLD}%"

    if ! check_backoff; then
        log "backoff → skip"
        sleep "$INTERVAL"
        continue
    fi

    # Overload protection
    [ "$(printf '%.0f' "$LOAD")" -ge 4 ] && { log "load high"; sleep "$INTERVAL"; continue; }
    [ -n "$PSI" ] && [ "$(printf '%.0f' "$PSI")" -ge 30 ] && { log "psi high"; sleep "$INTERVAL"; continue; }

    # Not enough cold pages
    [ "$COLD" -lt "$COLD_THRESHOLD" ] && { log "cold ratio small"; sleep "$INTERVAL"; continue; }

    # Now we allow recompress
    trigger_recompress

    sleep "$INTERVAL"
done
