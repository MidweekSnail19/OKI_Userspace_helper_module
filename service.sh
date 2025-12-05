#!/system/bin/sh

MODDIR=${0%/*}
LOGFILE="$MODDIR/zram_opt.log"
STATEFILE="$MODDIR/last_recomp"

# 尝试开启 MGLRU（如果内核支持）
if [ -w /sys/kernel/mm/lru_gen/enabled ]; then
    echo y > /sys/kernel/mm/lru_gen/enabled 2>/dev/null
    echo 1000 > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null
fi

INTERVAL=10
BACKOFF_MINUTES=1
# 降低冷页阈值，防止因为统计误差导致无法触发
COLD_THRESHOLD=10 

# 只定义一个 idle 阈值
IDLE_THRESHOLD=$((2*3600))
THRESHOLD_BYTES=1024

log() {
    echo "$(date '+%F %T') $*" >> "$LOGFILE"
    # 限制日志大小，保留最后1000行
    if [ $(wc -l < "$LOGFILE") -gt 1000 ]; then
        tail -n 1000 "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
    fi
}

##################################################
# GENERATION 区域冷页比率读取 (修正版)
##################################################
get_cold_ratio() {
    local total=0 cold=0
    local file=""
    
    if [ -r /sys/kernel/mm/lru_gen/stats ]; then
        file="/sys/kernel/mm/lru_gen/stats"
    elif [ -r /sys/kernel/mm/lru_gen/debug ]; then
        file="/sys/kernel/mm/lru_gen/debug"
    else
        # 无法读取文件，返回 100 强制允许（依赖 PSI 控制）
        echo 100
        return
    fi

    # 解析逻辑：
    # 查找包含 'gen' 和 'anon' 的行
    # 标准格式通常是: ... gen X ... anon Y ...
    # 我们认为 gen 数字较小的（相对于 max_seq）是冷的，但在脚本里很难获取 max_seq。
    # 这里采用一种模糊算法：统计所有 anon 页面。
    # 注意：准确判断 MGLRU 冷热极其复杂，这里简化为：
    # 如果能读到数据，就认为有数据；依靠 PSI 才是更准确的压力指标。
    
    # 实际上，在手机上脚本解析 stats 非常脆弱。
    # 建议：如果 PSI 低且 Load 低，就假设可以压缩。
    # 为了不破坏你的逻辑，这里做一个简单的 total 统计作为占位，
    # 并在下方 main loop 中主要依赖 PSI。
    
    # 简单的 awk 提取 anon 总量 (不区分冷热，因为无法准确获知当前 max_seq)
    # 这里的逻辑是：如果系统有匿名页，我们就尝试压缩。
    awk '
    /anon/ {
        for(i=1;i<=NF;i++) {
            if($i ~ /anon=/) {
                split($i, a, "="); val=a[2];
            } else if ($(i-1) == "anon") {
                val=$i;
            }
        }
        sum += val
    }
    END { print (sum > 0 ? 50 : 0) }' "$file" 
    
    # 修正注：原脚本的 "gen >= 3" 逻辑在长时间运行的系统上会失效（因为 gen 会无限增长）。
    # 这里直接返回 50 让它通过检查，把控制权交给 PSI。
}

##################################################
# 获取 PSI (AVG10)
##################################################
get_psi() {
    # 更加稳健的 awk 写法
    awk -F "=" '$1 ~ /avg10/ {print $2; exit}' /proc/pressure/memory 2>/dev/null
}

##################################################
# 系统负载
##################################################
get_load() {
    awk '{print $1}' /proc/loadavg
}

##################################################
# 回退窗口
##################################################
check_backoff() {
    [ ! -f "$STATEFILE" ] && return 0
    local last now diff
    last=$(cat "$STATEFILE" 2>/dev/null)
    # 防止文件损坏导致变量为空
    if [ -z "$last" ]; then return 0; fi
    
    now=$(date +%s)
    diff=$((now - last))
    # 确保 diff 也是数字
    if [ "$diff" -lt $((BACKOFF_MINUTES*60)) ]; then return 1; else return 0; fi
}

##################################################
# 重新压缩
##################################################
trigger_recompress() {
    log "trigger zram idle marking & recompress"
    
    # 1. 标记 Idle 页面
    # 修正：只写入单一整数
    echo "$IDLE_THRESHOLD" > /sys/block/zram0/idle 2>/dev/null
    
    # 给内核一点时间去标记
    sleep 0.5

    # 2. 触发重压缩
    # 优先使用 huge_idle (压缩效果最好)
    if grep -q "huge_idle" /sys/block/zram0/recompress; then
         if [ "$THRESHOLD_BYTES" -gt 0 ]; then
             echo "type=huge_idle threshold=$THRESHOLD_BYTES" > /sys/block/zram0/recompress 2>/dev/null
         else
             echo "type=huge_idle" > /sys/block/zram0/recompress 2>/dev/null
         fi
    fi
    
    # 可选：再触发 idle
    # echo "type=idle" > /sys/block/zram0/recompress 2>/dev/null

    date +%s > "$STATEFILE"
}

##################################################
# ==================== main loop ====================
##################################################

# 等待系统启动完成，避免开机由于负载高而误判
sleep 60

while true; do
    if [ ! -e /sys/block/zram0/recompress ]; then
        log "device not support recompress, exit"
        exit 1
    fi

    PSI=$(get_psi)
    LOAD=$(get_load)
    
    # 这里简化了 cold ratio，因为原逻辑不可靠
    # 只要 PSI 和 Load 低，就认为是“系统空闲，适合做整理”
    
    # 浮点数转整数处理，防止为空
    PSI_INT=$(printf '%.0f' "${PSI:-0}")
    LOAD_INT=$(printf '%.0f' "${LOAD:-0}")

    # log "PSI=$PSI LOAD=$LOAD" # 减少日志垃圾，仅在操作时记录或调试时开启

    if ! check_backoff; then
        sleep "$INTERVAL"
        continue
    fi

    # 检查：高负载跳过
    if [ "$LOAD_INT" -ge 4 ]; then
        sleep "$INTERVAL"
        continue
    fi

    # 检查：内存压力大跳过
    # 如果 PSI 很高，说明内存吃紧，此时不应该消耗 CPU 去压缩 ZRAM
    if [ "$PSI_INT" -ge 10 ]; then # 建议降低 PSI 阈值，30 已经很卡了
        sleep "$INTERVAL"
        continue
    fi

    trigger_recompress
    sleep "$INTERVAL"
done
