#!/usr/bin/env bash
# DX-M1 Performance Benchmark
#  모델별 측정: Latency, FPS(처리량), NPU 처리 시간, CPU·메모리·온도 사용률
#  장시간 안정성: 1분 구간을 반복하며 FPS 변동, 실패 횟수, 온도 추이 기록
#
# 사용법:
#   ./dx-bench.sh [-t 초] [-o 결과폴더] model1.dxnn [model2.dxnn ...]
#   ./dx-bench.sh -S 분 [-o 결과폴더] model.dxnn
set -u

DURATION=30          # 모델별 최대 처리량 측정 시간(초)
SINGLE_LOOPS=100     # 단일 추론 지연 측정 반복 횟수
STABILITY_MIN=0      # 0이면 모델별 측정, 1 이상이면 장시간 안정성 측정(분)
OUT_DIR="dx-bench-$(date +%Y%m%d-%H%M%S)"

usage() {
  echo "usage: $0 [-t seconds] [-o outdir] model.dxnn [...]" >&2
  echo "       $0 -S minutes [-o outdir] model.dxnn" >&2
  exit 2
}

while getopts "t:S:o:h" opt; do
  case "$opt" in
    t) DURATION="$OPTARG" ;;
    S) STABILITY_MIN="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -ge 1 ] || usage

DXRUN="$(command -v dxrun || command -v run_model || true)"
DXCLI="$(command -v dxrt-cli || command -v dxcli || true)"
[ -n "$DXRUN" ] || { echo "dxrun 이 없습니다. libdxrt-bin 을 설치하세요." >&2; exit 1; }
mkdir -p "$OUT_DIR"

# 자원 사용률 기록 ---------------------------------------------------------
# 1초마다 "시각,CPU%,사용메모리MB,SoC온도,NPU최고온도" 를 기록한다.
sampler() {
  local out="$1" interval="${2:-1}"
  local prev cur idle total pidle ptotal cpu mem soc npu
  echo "time,cpu_pct,mem_used_mb,soc_temp_c,npu_temp_c" > "$out"
  read -r -a prev < <(grep '^cpu ' /proc/stat)
  while :; do
    sleep "$interval"
    read -r -a cur < <(grep '^cpu ' /proc/stat)
    pidle=$((prev[4] + prev[5])); idle=$((cur[4] + cur[5]))
    ptotal=0; total=0
    for i in 1 2 3 4 5 6 7 8; do ptotal=$((ptotal + prev[i])); total=$((total + cur[i])); done
    cpu=$(awk -v t=$((total - ptotal)) -v i=$((idle - pidle)) 'BEGIN { if (t > 0) printf "%.1f", (t - i) * 100 / t; else print 0 }')
    prev=("${cur[@]}")
    mem=$(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%d", (t - a) / 1024}' /proc/meminfo)
    soc=$(awk '{printf "%.1f", $1 / 1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    npu=""
    [ -n "$DXCLI" ] && npu=$("$DXCLI" -s 2>/dev/null | sed -n "s/.*temperature \(-\{0,1\}[0-9]*\)'C.*/\1/p" | sort -n | tail -n1)
    echo "$(date +%H:%M:%S),$cpu,$mem,${soc},${npu}" >> "$out"
  done
}

# "평균CPU 최고CPU 최고메모리 최고SoC온도 최고NPU온도"
summarize_samples() {
  awk -F, 'NR > 1 {
      n++; c += $2; if ($2 > cm) cm = $2; if ($3 > mm) mm = $3
      if ($4 != "" && $4 > st) st = $4; if ($5 != "" && $5 > nt) nt = $5 }
    END { if (n == 0) { print "- - - - -"; exit }
      printf "%.1f %.1f %d %s %s\n", c / n, cm, mm, (st == "" ? "-" : st), (nt == "" ? "-" : nt) }' "$1"
}

# dxrun -v 출력에서 값 추출: "  - FPS : 123.4", "  - Latency Average : 5.6 ms"
# 단일 모드(-s)는 회차마다 결과를 출력하므로, 준비 시간이 섞인 첫 회차를 빼고 평균을 낸다.
metric() {
  grep -E "^ *- $2" "$1" | sed 's/^[^:]*: *\([0-9.]*\).*/\1/' |
    awk '{ v[NR] = $1 } END { if (NR == 0) exit; s = 0; f = (NR > 1 ? 2 : 1)
      for (i = f; i <= NR; i++) s += v[i]; printf "%.2f", s / (NR - f + 1) }'
}

throttled() { command -v vcgencmd >/dev/null && vcgencmd get_throttled 2>/dev/null | cut -d= -f2; }

print_env() {
  echo "# 측정 환경"
  echo "host=$(hostname) kernel=$(uname -r) date=$(date '+%Y-%m-%d %H:%M:%S')"
  [ -n "$DXCLI" ] && "$DXCLI" -i 2>/dev/null | grep -E 'FW version|RT Driver|PCIe Driver|PCIe  ' | sed 's/^ *\* */  /'
  local bdf; bdf="$(lspci -D -d 1ff4: 2>/dev/null | awk 'NR==1 {print $1}')"
  [ -n "$bdf" ] && echo "  PCIe link: $(cat /sys/bus/pci/devices/$bdf/current_link_speed) x$(cat /sys/bus/pci/devices/$bdf/current_link_width)"
}

# 모델별 측정 --------------------------------------------------------------
run_models() {
  local csv="$OUT_DIR/summary.csv" m name log1 log2 smp pid
  echo "model,single_latency_ms,single_npu_ms,fps,latency_avg_ms,npu_avg_ms,cpu_avg_pct,cpu_max_pct,mem_max_mb,soc_temp_max_c,npu_temp_max_c,result" > "$csv"
  for m in "$@"; do
    name="$(basename "$m" .dxnn)"
    log1="$OUT_DIR/${name}.single.log"; log2="$OUT_DIR/${name}.bench.log"; smp="$OUT_DIR/${name}.samples.csv"
    echo ">> $name : 단일 추론 ${SINGLE_LOOPS}회"
    "$DXRUN" -m "$m" -s -l "$SINGLE_LOOPS" -v > "$log1" 2>&1
    local rc1=$?
    echo ">> $name : 최대 처리량 ${DURATION}초"
    sampler "$smp" 1 & pid=$!
    "$DXRUN" -m "$m" -t "$DURATION" -v > "$log2" 2>&1
    local rc2=$?
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    local res=OK
    { [ $rc1 -ne 0 ] || [ $rc2 -ne 0 ] || grep -q 'dxrt-exception' "$log1" "$log2"; } && res=FAIL
    read -r cavg cmax mmax stmax ntmax < <(summarize_samples "$smp")
    echo "$name,$(metric "$log1" 'Latency'),$(metric "$log1" 'NPU Processing Time'),$(metric "$log2" 'FPS'),$(metric "$log2" 'Latency'),$(metric "$log2" 'NPU Processing Time'),$cavg,$cmax,$mmax,$stmax,$ntmax,$res" >> "$csv"
  done
  echo
  column -s, -t < "$csv"
}

# 장시간 안정성 ------------------------------------------------------------
run_stability() {
  local m="$1" name csv smp pid i log fps lat ok=0 ng=0
  name="$(basename "$m" .dxnn)"
  csv="$OUT_DIR/${name}.stability.csv"; smp="$OUT_DIR/${name}.stability.samples.csv"
  echo "minute,time,fps,latency_avg_ms,result,throttled" > "$csv"
  sampler "$smp" 10 & pid=$!
  trap 'kill $pid 2>/dev/null' EXIT
  for i in $(seq 1 "$STABILITY_MIN"); do
    log="$OUT_DIR/${name}.stability.$i.log"
    if "$DXRUN" -m "$m" -t 60 -v > "$log" 2>&1 && ! grep -q 'dxrt-exception' "$log"; then
      ok=$((ok + 1)); r=OK
    else
      ng=$((ng + 1)); r=FAIL
    fi
    fps="$(metric "$log" 'FPS')"; lat="$(metric "$log" 'Latency')"
    echo "$i,$(date +%H:%M:%S),$fps,$lat,$r,$(throttled)" >> "$csv"
    printf '  %3d/%d분 FPS %s, 지연 %s ms, %s\n' "$i" "$STABILITY_MIN" "${fps:--}" "${lat:--}" "$r"
    [ "$r" = OK ] && rm -f "$log"   # 실패한 구간의 로그만 남긴다
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo
  awk -F, -v ok="$ok" -v ng="$ng" 'NR > 1 && $3 != "" { n++; s += $3; q += $3 * $3; if (min == "" || $3 < min) min = $3; if ($3 > max) max = $3 }
    END { if (n == 0) { print "FPS 기록 없음"; exit }
      m = s / n; sd = sqrt(q / n - m * m)
      printf "구간 %d개 (성공 %d, 실패 %d)\nFPS 평균 %.1f, 최소 %.1f, 최대 %.1f, 변동계수 %.2f%%\n", n, ok, ng, m, min, max, (m > 0 ? sd / m * 100 : 0) }' "$csv"
  read -r cavg cmax mmax stmax ntmax < <(summarize_samples "$smp")
  echo "CPU 평균 ${cavg}% (최고 ${cmax}%), 메모리 최고 ${mmax} MB, SoC 최고 ${stmax}°C, NPU 최고 ${ntmax}°C"
  echo "throttled(마지막): $(throttled)"
}

{ print_env; echo; } | tee "$OUT_DIR/env.txt"
if [ "$STABILITY_MIN" -gt 0 ]; then
  run_stability "$1" | tee "$OUT_DIR/stability.txt"
else
  run_models "$@" | tee "$OUT_DIR/summary.txt"
fi
echo "결과 폴더: $OUT_DIR"
