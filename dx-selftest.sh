#!/usr/bin/env bash
# DX-M1 Hardware Self-Test
# PCIe, 드라이버, 펌웨어, NPU, 서비스 상태를 점검하고 PASS/WARN/FAIL로 판정한다.
# 사용법: ./dx-selftest.sh [-m <model.dxnn>] [-l <loops>] [-o <log file>]
set -u

MODEL=""
LOOPS=100
LOG_FILE=""
DX_VENDOR="1ff4"
SUPPORTED_DEVICE_IDS="0000 0100"   # dxrt-driver-dkms 2.6.0 의 M1 PCI ID 표

usage() {
  echo "usage: $0 [-m model.dxnn] [-l loops] [-o logfile]" >&2
  echo "  -m  지정한 모델로 추론 시험까지 실행" >&2
  echo "  -l  추론 시험 반복 횟수 (기본 $LOOPS)" >&2
  echo "  -o  결과를 파일에도 저장" >&2
  exit 2
}

while getopts "m:l:o:h" opt; do
  case "$opt" in
    m) MODEL="$OPTARG" ;;
    l) LOOPS="$OPTARG" ;;
    o) LOG_FILE="$OPTARG" ;;
    *) usage ;;
  esac
done

if [ -n "$LOG_FILE" ]; then
  exec > >(tee "$LOG_FILE") 2>&1
fi

PASS=0; WARN=0; FAIL=0
if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; else G=; Y=; R=; B=; N=; fi

result() {   # result <PASS|WARN|FAIL|INFO> <항목> <내용>
  local color
  case "$1" in
    PASS) PASS=$((PASS + 1)); color=$G ;;
    WARN) WARN=$((WARN + 1)); color=$Y ;;
    FAIL) FAIL=$((FAIL + 1)); color=$R ;;
    *) color= ;;
  esac
  # 한글 폭은 printf 폭 지정으로 맞출 수 없어 "항목: 내용" 형태로 출력한다.
  printf '  %s[%-4s]%s %s: %s\n' "$color" "$1" "$N" "$2" "$3"
}

section() { printf '\n%s== %s ==%s\n' "$B" "$1" "$N"; }

version_ge() {   # version_ge A B : A >= B
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

DXCLI="$(command -v dxrt-cli || command -v dxcli || true)"
DXRUN="$(command -v dxrun || command -v run_model || true)"

printf '%sDX-M1 Hardware Self-Test%s  (%s, %s, kernel %s)\n' "$B" "$N" \
  "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')" "$(uname -r)"

# 1. PCIe ---------------------------------------------------------------
section "1. PCIe"
BDF="$(lspci -D -d "${DX_VENDOR}:" 2>/dev/null | awk 'NR==1 {print $1}')"
if [ -z "$BDF" ]; then
  result FAIL "PCIe 장치" "DEEPX 장치(vendor ${DX_VENDOR})가 없습니다. 모듈 장착과 config.txt의 dtparam=pciex1을 확인하세요."
else
  SYS="/sys/bus/pci/devices/$BDF"
  DEV_ID="$(sed 's/^0x//' "$SYS/device")"
  CLASS="$(sed 's/^0x//' "$SYS/class")"
  if printf '%s\n' $SUPPORTED_DEVICE_IDS | grep -qx "$DEV_ID"; then
    result PASS "PCIe 장치" "$BDF ${DX_VENDOR}:${DEV_ID} (class ${CLASS})"
  else
    result FAIL "PCIe 장치" "$BDF ${DX_VENDOR}:${DEV_ID} (class ${CLASS}) — 정상 ID가 아닙니다. 전원을 완전히 차단 후 다시 켜 보세요."
  fi
  SPEED="$(cat "$SYS/current_link_speed" 2>/dev/null)"
  WIDTH="$(cat "$SYS/current_link_width" 2>/dev/null)"
  MAXSPEED="$(cat "$SYS/max_link_speed" 2>/dev/null)"
  case "$SPEED" in
    8.0*) result PASS "PCIe 링크" "${SPEED} x${WIDTH} (Gen3, 장치 최대 ${MAXSPEED})" ;;
    5.0*) result WARN "PCIe 링크" "${SPEED} x${WIDTH} (Gen2) — Gen3 설정(dtparam=pciex1_gen=3)을 권장합니다." ;;
    *)    result WARN "PCIe 링크" "${SPEED:-알 수 없음} x${WIDTH:-?}" ;;
  esac
fi

# 2. 드라이버 ------------------------------------------------------------
section "2. 드라이버"
DRV_PKG="$(dpkg-query -W -f='${Version}' dxrt-driver-dkms 2>/dev/null || true)"
if [ -n "$DRV_PKG" ]; then
  result PASS "드라이버 패키지" "dxrt-driver-dkms ${DRV_PKG}"
else
  result FAIL "드라이버 패키지" "dxrt-driver-dkms 가 설치되어 있지 않습니다."
fi
if ls "/lib/modules/$(uname -r)/updates/dkms/"dxrt_driver.ko* >/dev/null 2>&1; then
  result PASS "현재 커널용 모듈" "/lib/modules/$(uname -r)/updates/dkms"
else
  result FAIL "현재 커널용 모듈" "현재 커널($(uname -r))용 모듈이 빌드되지 않았습니다. 커널 헤더 설치 후 드라이버 패키지를 다시 설치하세요."
fi
for mod in dx_dma dxrt_driver; do
  if [ -d "/sys/module/$mod" ]; then
    result PASS "커널 모듈 $mod" "적재됨"
  else
    result FAIL "커널 모듈 $mod" "적재되지 않았습니다. (sudo modprobe dx_dma)"
  fi
done
if [ -n "${BDF:-}" ]; then
  BOUND="$(basename "$(readlink "/sys/bus/pci/devices/$BDF/driver" 2>/dev/null)" 2>/dev/null)"
  if [ -n "$BOUND" ]; then
    result PASS "장치-드라이버 연결" "$BOUND"
  else
    result FAIL "장치-드라이버 연결" "PCIe 장치에 드라이버가 연결되지 않았습니다."
  fi
fi
NODES="$(ls /dev/dxrt* 2>/dev/null | tr '\n' ' ')"
if [ -n "$NODES" ]; then
  result PASS "장치 파일" "$NODES"
else
  result FAIL "장치 파일" "/dev/dxrt* 가 없습니다."
fi

# 3. 런타임과 서비스 -----------------------------------------------------
section "3. 런타임·서비스"
RT_PKG="$(dpkg-query -W -f='${Version}' libdxrt-bin 2>/dev/null || true)"
if [ -n "$DXCLI" ]; then
  RT_VER="$("$DXCLI" -v 2>/dev/null | sed -n 's/^DXRT \(v[^ ]*\).*/\1/p' | head -n1)"
  result PASS "DX-RT 런타임" "${RT_VER:-확인 불가} (패키지 libdxrt-bin ${RT_PKG:-없음})"
else
  result FAIL "DX-RT 런타임" "dxrt-cli 가 없습니다. libdxrt-bin 을 설치하세요."
fi
if systemctl is-active --quiet dxrt.service; then
  result PASS "dxrt.service" "active ($(systemctl is-enabled dxrt.service 2>/dev/null))"
else
  result FAIL "dxrt.service" "$(systemctl is-active dxrt.service 2>/dev/null) — sudo systemctl restart dxrt.service"
fi

# 4. 펌웨어·NPU ----------------------------------------------------------
section "4. 펌웨어·NPU"
if [ -n "$DXCLI" ]; then
  STATUS="$("$DXCLI" -s 2>&1)"
  if printf '%s' "$STATUS" | grep -q 'dxrt-exception'; then
    result FAIL "NPU 상태 조회" "$(printf '%s' "$STATUS" | grep -o '"[^"]*"' | head -n1) — 전원 차단 후 재투입, 펌웨어 확인"
  else
    result PASS "NPU 상태 조회" "dxrt-cli -s 정상 응답"
    FW_VER="$(printf '%s\n' "$STATUS" | grep -iE 'fw|firmware' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    FW_MIN="$("$DXCLI" -v 2>/dev/null | sed -n 's/.*Firmware: v\([0-9.]*\).*/\1/p' | head -n1)"
    if [ -z "$FW_VER" ]; then
      result WARN "펌웨어 버전" "출력에서 버전을 찾지 못했습니다."
    elif [ -n "$FW_MIN" ] && ! version_ge "$FW_VER" "$FW_MIN"; then
      result FAIL "펌웨어 버전" "v${FW_VER} < 최소 요구 v${FW_MIN} — 펌웨어 업데이트가 필요합니다."
    else
      result PASS "펌웨어 버전" "v${FW_VER} (최소 요구 v${FW_MIN:-?})"
    fi
    # 형식: "NPU 0: voltage 750 mV, clock 1000 MHz, temperature 40'C"
    TEMP="$(printf '%s\n' "$STATUS" | sed -n "s/.*temperature \(-\{0,1\}[0-9]*\)'C.*/\1/p" | sort -n | tail -n1)"
    [ -n "$TEMP" ] && result INFO "NPU 온도" "최고 ${TEMP}°C"
  fi
fi
if journalctl -k -b --no-pager >/dev/null 2>&1; then
  ERRS="$(journalctl -k -b --no-pager 2>/dev/null | grep -ciE 'dxrt.*(timeout|error|fail)|dx_dma.*(error|fail)')"
  if [ "$ERRS" -eq 0 ]; then
    result PASS "커널 로그" "이번 부팅에서 DEEPX 오류 없음"
  else
    result WARN "커널 로그" "DEEPX 관련 오류 ${ERRS}건 — journalctl -k -b | grep -i dx"
  fi
else
  result INFO "커널 로그" "권한이 없어 건너뜀 (sudo 로 실행하면 확인)"
fi

# 5. 추론 시험(선택) -----------------------------------------------------
if [ -n "$MODEL" ]; then
  section "5. 추론 시험"
  if [ ! -f "$MODEL" ]; then
    result FAIL "모델 파일" "$MODEL 이 없습니다."
  elif [ -z "$DXRUN" ]; then
    result FAIL "추론 시험" "dxrun 이 없습니다."
  else
    OUT="$("$DXRUN" -m "$MODEL" -l "$LOOPS" 2>&1)"; RC=$?
    FPS="$(printf '%s\n' "$OUT" | grep -iE 'fps' | grep -oE '[0-9]+(\.[0-9]+)?' | tail -n1)"
    if [ $RC -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'dxrt-exception'; then
      result PASS "추론 시험" "$(basename "$MODEL") ${LOOPS}회 완료${FPS:+, FPS ${FPS}}"
    else
      result FAIL "추론 시험" "$(basename "$MODEL") 실패 (exit $RC)"
      printf '%s\n' "$OUT" | tail -n 5 | sed 's/^/        /'
    fi
  fi
fi

# 요약 ------------------------------------------------------------------
printf '\n%s결과: PASS %d / WARN %d / FAIL %d%s\n' "$B" "$PASS" "$WARN" "$FAIL" "$N"
if [ "$FAIL" -gt 0 ]; then
  printf '%s판정: 점검 실패 — FAIL 항목의 안내를 따라 조치하세요.%s\n' "$R" "$N"
  exit 1
fi
printf '%s판정: 정상%s\n' "$G" "$N"
exit 0
