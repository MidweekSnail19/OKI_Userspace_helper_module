#!/system/bin/sh
#
# zram_recomp.sh
# lz4 为主：平时只重压 idle/huge_idle，PSI 高时再动 huge
#

MODDIR=${MODDIR:-${0%/*}}
LOGFILE="$MODDIR/zram_recomp.log"
STATEFILE="$MODDIR/zram_last"

# 不写日志：所有 log 调用直接空操作
log() { :; }

# 对应 Params::default()
BACKOFF_DURATION=1800        # 30 分钟（秒）
MIN_IDLE=7200                # 2 小时（秒）
MAX_IDLE=14400               # 4 小时（秒）
# 正常情况下 idle_age 用中值 3h，高压时可以用更激进的 2h
IDLE_AGE_NORMAL=$(( (MIN_IDLE + MAX_IDLE) / 2 ))  # 10800 秒 = 3h
IDLE_AGE_HIGH=$MIN_IDLE                           # 7200 秒 = 2h
THRESHOLD_BYTES=1024         # 1 KiB

# PSI 设置
USE_PSI=1
# memory some avg10 >= 0.20 视为“压力比较高”
PSI_HIGH_THRESHOLD=0.20

boot_uptime() {
    awk '{print int($1)}' /proc/uptime 2>/dev/null
}

zram_ready() {
    [ -e /sys/block/zram0/idle ] && [ -e /sys/block/zram0/recompress ]
}

# 读取 memory PSI 的 some avg10（浮点数，例如 0.15）
get_mem_psi_some_avg10() {
    [ -r /proc/pressure/memory ] || return 1

    awk '/^some / {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^avg10=/) {
                gsub("avg10=", "", $i);
                print $i;
                exit
            }
        }
    }' /proc/pressure/memory 2>/dev/null
}

zram_mark_and_recompress() {
    if ! zram_ready; then
        log "zram0 idle/recompress interface not found, abort."
        return 1
    fi

    local now last delta
    now=$(boot_uptime)
    if [ -z "$now" ]; then
        log "Cannot read /proc/uptime, abort."
        return 1
    fi

    if [ -f "$STATEFILE" ]; then
        last=$(cat "$STATEFILE" 2>/dev/null || echo 0)
    else
        last=0
    fi

    delta=$((now - last))

    # 1) backoff：30 分钟内只允许运行一次完整重压流程
    if [ "$delta" -lt "$BACKOFF_DURATION" ]; then
        log "Skip: backoff not reached (delta=${delta}s < ${BACKOFF_DURATION}s)"
        return 1
    fi

    # 2) 看 PSI：决定是“轻度模式”还是“高压模式”
    local psi_val high_pressure idle_age
    high_pressure=0
    idle_age=$IDLE_AGE_NORMAL

    if [ "$USE_PSI" -eq 1 ]; then
        psi_val=$(get_mem_psi_some_avg10)
        if [ -n "$psi_val" ]; then
            # psi_val >= PSI_HIGH_THRESHOLD → 高压
            if awk "BEGIN { exit !($psi_val >= $PSI_HIGH_THRESHOLD) }"; then
                high_pressure=1
                idle_age=$IDLE_AGE_HIGH
                log "High memory pressure: PSI some avg10=${psi_val} >= ${PSI_HIGH_THRESHOLD}"
            else
                log "Normal memory pressure: PSI some avg10=${psi_val} < ${PSI_HIGH_THRESHOLD}"
            fi
        else
            log "PSI not available, treat as normal pressure"
        fi
    else
        log "PSI check disabled, always treat as normal pressure"
    fi

    # 3) 按 idle_age 给 zram block 打 idle 标记
    if echo "$idle_age" > /sys/block/zram0/idle 2>/dev/null; then
        log "Marked zram0 pages idle (age >= ${idle_age}s)"
    else
        log "Failed to mark idle pages with age=${idle_age}s"
        # 不 return，让下面的 recompress 自己决定有没有 idle block
    fi

    # 4) 轻度模式（始终执行）：
    #    - huge_idle：既大又冷 → 直接送 zstd，收益最高
    #    - idle：普通冷页 → �慢慢进 zstd
    if echo "type=huge_idle threshold=${THRESHOLD_BYTES}" > /sys/block/zram0/recompress 2>/dev/null; then
        log "Triggered recompress: type=huge_idle threshold=${THRESHOLD_BYTES}"
    else
        log "Failed to trigger huge_idle recompress"
    fi

    if echo "type=idle threshold=${THRESHOLD_BYTES}" > /sys/block/zram0/recompress 2>/dev/null; then
        log "Triggered recompress: type=idle threshold=${THRESHOLD_BYTES}"
    else
        log "Failed to trigger idle recompress"
    fi

    # 5) 高压模式时再动 huge：
    #    - 这部分是“巨大但目前没被判 idle”的块，可能还稍微温一点
    #    - 只有在 PSI 高时才把它们推去 zstd，避免平时过度压缩影响前台
    if [ "$high_pressure" -eq 1 ]; then
        if echo "type=huge threshold=${THRESHOLD_BYTES}" > /sys/block/zram0/recompress 2>/dev/null; then
            log "Triggered recompress: type=huge threshold=${THRESHOLD_BYTES} (high pressure)"
        else
            log "Failed to trigger huge recompress (high pressure)"
        fi
    else
        log "Skip huge recompress in normal pressure"
    fi

    echo "$now" > "$STATEFILE"
    log "Recompress cycle completed at uptime=${now}s (backoff=${BACKOFF_DURATION}s, high_pressure=${high_pressure})"
    return 0
}

# 直接运行测试：sh zram_recomp.sh --run-once
if [ "$1" = "--run-once" ]; then
    zram_mark_and_recompress
fi# 读取 memory PSI 的 some avg10（浮点数，例如 0.15）
get_mem_psi_some_avg10() {
    [ -r /proc/pressure/memory ] || return 1

    awk '/^some / {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^avg10=/) {
                gsub("avg10=", "", $i);
                print $i;
                exit
            }
        }
    }' /proc/pressure/memory 2>/dev/null
}

zram_mark_and_recompress() {
    if ! zram_ready; then
        log "zram0 idle/recompress interface not found, abort."
        return 1
    fi

    local now last delta
    now=$(boot_uptime)
    if [ -z "$now" ]; then
        log "Cannot read /proc/uptime, abort."
        return 1
    fi

    if [ -f "$STATEFILE" ]; then
        last=$(cat "$STATEFILE" 2>/dev/null || echo 0)
    else
        last=0
    fi

    delta=$((now - last))

    # 1) backoff：30 分钟内只允许运行一次完整重压流程
    if [ "$delta" -lt "$BACKOFF_DURATION" ]; then
        log "Skip: backoff not reached (delta=${delta}s < ${BACKOFF_DURATION}s)"
        return 1
    fi

    # 2) 看 PSI：决定是“轻度模式”还是“高压模式”
    local psi_val high_pressure idle_age
    high_pressure=0
    idle_age=$IDLE_AGE_NORMAL

    if [ "$USE_PSI" -eq 1 ]; then
        psi_val=$(get_mem_psi_some_avg10)
        if [ -n "$psi_val" ]; then
            # psi_val >= PSI_HIGH_THRESHOLD → 高压
            if awk "BEGIN { exit !($psi_val >= $PSI_HIGH_THRESHOLD) }"; then
                high_pressure=1
                idle_age=$IDLE_AGE_HIGH
                log "High memory pressure: PSI some avg10=${psi_val} >= ${PSI_HIGH_THRESHOLD}"
            else
                log "Normal memory pressure: PSI some avg10=${psi_val} < ${PSI_HIGH_THRESHOLD}"
            fi
        else
            log "PSI not available, treat as normal pressure"
        fi
    else
        log "PSI check disabled, always treat as normal pressure"
    fi

    # 3) 按 idle_age 给 zram block 打 idle 标记
    if echo "$idle_age" > /sys/block/zram0/idle 2>/dev/null; then
        log "Marked zram0 pages idle (age >= ${idle_age}s)"
    else
        log "Failed to mark idle pages with age=${idle_age}s"
        # 不 return，让下面的 recompress 自己决定有没有 idle block
    fi

    # 4) 轻度模式（始终执行）：
    #    - huge_idle：既大又冷 → 直接送 zstd，收益最高
    #    - idle：普通冷页 → 慢慢进 zstd
    if echo "type=huge_idle threshold=${THRESHOLD_BYTES}" > /sys/block/zram0/recompress 2>/dev/null; then
        log "Triggered recompress: type=huge_idle threshold=${THRESHOLD_BYTES}"
    else
        log "Failed to trigger huge_idle recompress"
    fi

    if echo "type=idle threshold=${THRESHOLD_BYTES}" > /sys/block/zram0/recompress 2>/dev/null; then
        log "Triggered recompress: type=idle threshold=${THRESHOLD_BYTES}"
    else
        log "Failed to trigger idle recompress"
    fi

    # 5) 高压模式时再动 huge：
    #    - 这部分是“巨大但目前没被判 idle”的块，可能还稍微温一点
    #    - 只有在 PSI 高时才把它们推去 zstd，避免平时过度压缩影响前台
    if [ "$high_pressure" -eq 1 ]; then
        if echo "type=huge threshold=${THRESHOLD_BYTES}" > /sys/block/zram0/recompress 2>/dev/null; then
            log "Triggered recompress: type=huge threshold=${THRESHOLD_BYTES} (high pressure)"
        else
            log "Failed to trigger huge recompress (high pressure)"
        fi
    else
        log "Skip huge recompress in normal pressure"
    fi

    echo "$now" > "$STATEFILE"
    log "Recompress cycle completed at uptime=${now}s (backoff=${BACKOFF_DURATION}s, high_pressure=${high_pressure})"
    return 0
}

# 直接运行测试：sh zram_recomp.sh --run-once
if [ "$1" = "--run-once" ]; then
    zram_mark_and_recompress
fi
