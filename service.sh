#!/system/bin/sh
MODDIR=${0%/*}
# 确保 utils.sh 存在，防止报错
[ -f "$MODDIR/utils.sh" ] && . "$MODDIR/utils.sh"


# --- ZRAM Setup ---
swapoff "/dev/block/zram0" >/dev/null 2>&1
lock_val "1" "/sys/class/block/zram0/reset"
lock_val "0" "/sys/block/zram0/mem_limit"
# 设置双算法：LZ4 (快) + ZSTD (高压缩)
lock_val "lz4" "/sys/block/zram0/comp_algorithm"
echo "algo=zstd priority=1" > /sys/block/zram0/recomp_algorithm 2>/dev/null
lock_val "$(awk 'NR==1{print $2*2048}' </proc/meminfo)" "/sys/class/block/zram0/disksize"
mkswap "/dev/block/zram0" >/dev/null 2>&1
swapon "/dev/block/zram0" >/dev/null 2>&1
rm "/dev/block/zram0"
touch "/dev/block/zram0"

# --- VM & IO Optimization ---

mask_val "60" /proc/sys/vm/swappiness

# 这里的 page-cluster=0 是非常正确的，ZRAM 不需要预读
mask_val "0" /proc/sys/vm/page-cluster

# 其他 VM 参数
mask_val "20" /proc/sys/vm/compaction_proactiveness
mask_val "32768" /proc/sys/vm/min_free_kbytes
mask_val "150" /proc/sys/vm/watermark_scale_factor
mask_val "15000" /proc/sys/vm/watermark_boost_factor


# Dirty Ratios (保持你的激进设置，利于跑分/突发写入)
mask_val "5" /proc/sys/vm/dirty_ratio
mask_val "2" /proc/sys/vm/dirty_background_ratio
mask_val "60" /proc/sys/vm/dirtytime_expire_seconds

lock_val "1000" /sys/kernel/mm/lru_gen/min_ttl_ms
lock_val "Y" /sys/kernel/mm/lru_gen/enabled
exec_system "dumpsys osensemanager proc debug feature 0"
exec_system "dumpsys osensemanager memory resrelease switch 0"

# IO Queue 优化
for sd in /sys/block/*; do
    lock_val "none" "$sd/queue/scheduler"
    lock_val "0" "$sd/queue/iostats"
    lock_val "2" "$sd/queue/nomerges"
    lock_val "128" "$sd/queue/read_ahead_kb"
    lock_val "128" "$sd/bdi/read_ahead_kb"
done
    exec_system "device_config set_sync_disabled_for_tests until_reboot"
    exec_system "device_config put activity_manager max_cached_processes 65535"
    exec_system "device_config put activity_manager max_phantom_processes 65535"
    exec_system "device_config put lmkd_native use_minfree_levels false"
    exec_system "device_config delete lmkd_native thrashing_limit_critical"
    exec_system "device_config put activity_manager use_compaction false"
    exec_system "device_config put activity_manager_native_boot use_freezer false"

    exec_system "settings put global settings_enable_monitor_phantom_procs false"
# ... 前面是 IO 优化和 swap 挂载 ...

chmod 755 "$MODDIR/zram_recomp.sh" 2>/dev/null
. "$MODDIR/zram_recomp.sh"

(
    USE_PSI=1
    INTERVAL=600

    renice -n 10 -p $$ >/dev/null 2>&1 || renice 10 $$ >/dev/null 2>&1
    if command -v ionice >/dev/null 2>&1; then
        ionice -c3 -p $$ >/dev/null 2>&1
    fi

    while true; do
        zram_mark_and_recompress
        sleep "$INTERVAL"
    done
) &
