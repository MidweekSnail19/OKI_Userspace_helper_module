insmod /system_dlkm/lib/modules/zsmalloc.ko 
insmod ${0%/*}/ko/zram.ko 
mount -t debugfs none /sys/kernel/debug
