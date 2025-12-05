swapoff /dev/block/zram0
echo 1 > /sys/block/zram0/reset
echo 0 > /sys/block/zram0/mem_limit
echo lz4 > /sys/block/zram0/comp_algorithm
echo "algo=zstd priority=1" > /sys/block/zram0/recomp_algorithm
echo $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) * 2048 )) > /sys/class/block/zram0/disksize 
mkswap /dev/block/zram0
swapon /dev/block/zram0
rm /dev/block/zram0
touch /dev/block/zram0
