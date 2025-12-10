#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/utils.sh"
#set zram
swapoff "/dev/block/zram0"
lock_val "1" "/sys/class/block/zram0/reset"
lock_val "0" "/sys/class/block/zram0/mem_limit"
lock_val "lz4" "/sys/class/block/zram0/comp_algorithm"
lock_val "algo=zstd priority=1" "/sys/block/zram0/recomp_algorithm"
lock_val "$(awk 'NR==1{print $2*2048}' </proc/meminfo)" "/sys/class/block/zram0/disksize"
mkswap "/dev/block/zram0"
/system/bin/swapon "/dev/block/zram0"
rm "/dev/block/zram0"
touch "/dev/block/zram0"
#io optimization
mask_val "1" /proc/sys/vm/swappiness
mask_val "20" /proc/sys/vm/compaction_proactiveness
mask_val "0" /proc/sys/vm/page-cluster
mask_val "32768" /proc/sys/vm/min_free_kbytes
mask_val "150" /proc/sys/vm/watermark_scale_factor
mask_val "15000" /proc/sys/vm/watermark_boost_factor
mask_val "1" /proc/sys/vm/overcommit_memory
mask_val "5" /proc/sys/vm/dirty_ratio
mask_val "2" /proc/sys/vm/dirty_background_ratio
mask_val "60" /proc/sys/vm/dirtytime_expire_seconds
lock_val "1000" /sys/kernel/mm/lru_gen/min_ttl_ms
lock_val "Y" /sys/kernel/mm/lru_gen/enabled
for sd in /sys/block/*; do
        lock_val "none" "$sd/queue/scheduler"
        lock_val "0" "$sd/queue/iostats"
        lock_val "2" "$sd/queue/nomerges"
        lock_val "128" "$sd/queue/read_ahead_kb"
        lock_val "128" "$sd/bdi/read_ahead_kb"
    done


chmod 755 "$MODDIR/zram_recomp.sh" 2>/dev/null
. "$MODDIR/zram_recomp.sh"

# 每 15 分钟尝试一次，真正的 30 分钟 backoff 在脚本内部控制
INTERVAL=900

while true; do
    zram_mark_and_recompress
    sleep "$INTERVAL"
done
