#!/system/bin/sh
# zram_recomp.sh (idle + huge_idle + optional huge, nostate)

THRESHOLD_BYTES=1024
MIN_DELTA_BYTES=$((32 * 1024 * 1024))

MIN_IDLE=7200
MAX_IDLE=14400
IDLE_AGE_NORMAL=$(( (MIN_IDLE + MAX_IDLE) / 2 ))  # 10800

USE_PSI=${USE_PSI:-1}
PSI_STOP_SOME=${PSI_STOP_SOME:-0.20}
PSI_STOP_FULL=${PSI_STOP_FULL:-0.05}

zram_ready() {
  [ -w /sys/block/zram0/idle ] && [ -w /sys/block/zram0/recompress ]
}

get_mem_psi_avg10() {
  # $1 = some|full
  [ -r /proc/pressure/memory ] || return 1
  awk -v k="$1" '
    $1==k {
      for(i=1;i<=NF;i++){
        if($i ~ /^avg10=/){
          sub("avg10=","",$i); print $i; exit
        }
      }
    }' /proc/pressure/memory 2>/dev/null
}

zram_metric_bytes() {
  local s
  s="$(cat /sys/block/zram0/mm_stat 2>/dev/null)" || return 1
  case "$s" in
    *"orig_data_size="*)
      echo "$s" | tr ' ' '\n' | awk -F= '$1=="orig_data_size"{print $2; exit}'
      ;;
    *)
      echo "$s" | awk '{print ($1>0)?$1:0}'
      ;;
  esac
}

zram_mark_and_recompress() {
  # 0) 必须先确认内核接口存在
  if ! zram_ready; then
    return 1
  fi

  # 1) PSI 高就暂停（你原来的语义：直接停）
  if [ "$USE_PSI" -ne 0 ]; then
    local s f
    s="$(get_mem_psi_avg10 some)"
    f="$(get_mem_psi_avg10 full)"

    [ -n "$f" ] && awk "BEGIN{exit !($f >= $PSI_STOP_FULL)}" && return 0
    [ -n "$s" ] && awk "BEGIN{exit !($s >= $PSI_STOP_SOME)}" && return 0
  fi

  # 2) metric 读取失败/为空：直接退出，避免算术炸
  local m
  m="$(zram_metric_bytes)" || return 1
  [ -z "$m" ] && return 1

  # 3) 变化不大就跳过（常驻变量，无 statefile）
  if [ -n "${_ZRAM_LAST_METRIC:-}" ]; then
    local d=$(( m - _ZRAM_LAST_METRIC ))
    [ "$d" -lt 0 ] && d=$(( -d ))
    [ "$d" -lt "$MIN_DELTA_BYTES" ] && return 0
  fi
  _ZRAM_LAST_METRIC="$m"

  # 4) 标记冷页
  echo "$IDLE_AGE_NORMAL" > /sys/block/zram0/idle 2>/dev/null

  # 5) 重压顺序：huge_idle（收益最大）-> idle（普通冷页）
  #    如果你的内核不支持 huge_idle，这条会失败但不影响后面的 idle
  echo "type=huge_idle threshold=${THRESHOLD_BYTES}" > /sys/block/zram0/recompress 2>/dev/null
  echo "type=idle threshold=${THRESHOLD_BYTES}"      > /sys/block/zram0/recompress 2>/dev/null

  return 0
}

# 可选：手动单次测试
[ "$1" = "--run-once" ] && zram_mark_and_recompress
