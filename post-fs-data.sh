insmod /system_dlkm/lib/modules/zsmalloc.ko 
insmod ${0%/*}/ko/zram.ko 
echo lz4 > /sys/block/zram0/comp_algorithm 
echo $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) * 2048 )) > /sys/class/block/zram0/disksize 
echo "algo=zstd priority=1" > /sys/block/zram0/recomp_algorithm 
mount -t debugfs none /sys/kernel/debug
