#!/bin/bash
#
# run-qemu-uboot.sh - Boot the full chain in the self-built QEMU:
#
#   QEMU generic loader -> U-Boot -> Linux -> Buildroot rootfs
#
# QEMU's mcimx6ul-evk machine has no i.MX boot ROM/HAB model, so the
# headerless u-boot-dtb.bin is loaded at TEXT_BASE (0x87800000) with
# -device loader.  U-Boot then reads zImage + dtb from partition 1 and the
# kernel mounts the rootfs from partition 2 of the attached SD image.
#
# Usage:
#   scripts/qemu_helper/run-qemu-uboot.sh [OPTIONS]
#
# Options:
#   --image=PATH       SD/eMMC image (default:
#                      out/release-latest/images/imx6ull-aes-emmc.img)
#   --uboot-bin=PATH   headerless U-Boot (default: out/uboot/u-boot-dtb.bin)
#   --smoke            non-interactive boot test; waits for --expect patterns
#   --expect=PATTERN   grep -E pattern (repeatable; default "buildroot login:")
#   --timeout=SEC      smoke timeout (default 180)
#   --log=PATH         smoke UART log (default out/qemu/uboot-boot.log)
#   --display=TYPE     interactive display: gtk or vnc; serial stays on stdio
#   -h, --help         show this help
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
QEMU_BIN="${QEMU_BIN:-${PROJECT_ROOT}/out/qemu/build/qemu-system-arm}"
IMAGE="${PROJECT_ROOT}/out/release-latest/images/imx6ull-aes-emmc.img"
UBOOT_BIN="${PROJECT_ROOT}/out/uboot/u-boot-dtb.bin"
SMOKE=0
TIMEOUT=180
LOG_PATH="${PROJECT_ROOT}/out/qemu/uboot-boot.log"
DISPLAY_TYPE=""
EXPECTS=()

log() { echo "[run-qemu-uboot] $*"; }
die() { echo "[run-qemu-uboot] error: $*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^#   -h, --help/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image=*)        IMAGE="${1#*=}" ;;
        --image)          shift; [[ $# -gt 0 ]] || die "--image requires a value"; IMAGE="$1" ;;
        --uboot-bin=*)    UBOOT_BIN="${1#*=}" ;;
        --uboot-bin)      shift; [[ $# -gt 0 ]] || die "--uboot-bin requires a value"; UBOOT_BIN="$1" ;;
        --smoke)          SMOKE=1 ;;
        --expect=*)       EXPECTS+=("${1#*=}") ;;
        --expect)         shift; [[ $# -gt 0 ]] || die "--expect requires a value"; EXPECTS+=("$1") ;;
        --timeout=*)      TIMEOUT="${1#*=}" ;;
        --timeout)        shift; [[ $# -gt 0 ]] || die "--timeout requires a value"; TIMEOUT="$1" ;;
        --log=*)          LOG_PATH="${1#*=}" ;;
        --log)            shift; [[ $# -gt 0 ]] || die "--log requires a value"; LOG_PATH="$1" ;;
        --display=*)      DISPLAY_TYPE="${1#*=}" ;;
        --display)        shift; [[ $# -gt 0 ]] || die "--display requires a value"; DISPLAY_TYPE="$1" ;;
        -h|--help)        usage ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

[[ "${TIMEOUT}" =~ ^[0-9]+$ ]] || die "--timeout must be an integer"
[[ -x "${QEMU_BIN}" ]] || die "self-built QEMU not found: ${QEMU_BIN} (run scripts/build_helper/build-qemu.sh)"
[[ -f "${IMAGE}" ]] || die "image not found: ${IMAGE} (run assemble-qemu-image.sh)"
[[ -f "${UBOOT_BIN}" ]] || die "U-Boot loader image not found: ${UBOOT_BIN} (run build-uboot.sh)"

QEMU_ARGS=(
    -M mcimx6ul-evk
    -m 512M
    -device "loader,file=${UBOOT_BIN},addr=0x87800000,cpu-num=0"
    -drive "file=${IMAGE},if=sd,index=1,format=raw"
)

if [[ "${SMOKE}" -eq 0 ]]; then
    log "QEMU:    ${QEMU_BIN}"
    log "U-Boot:  ${UBOOT_BIN}"
    log "image:   ${IMAGE}"
    log "chain:   loader -> U-Boot -> zImage/dtb (p1) -> rootfs (p2)"
    log "console: ttymxc0, interactive; Ctrl-A X quits"
    if [[ -n "${DISPLAY_TYPE}" ]]; then
        exec "${QEMU_BIN}" "${QEMU_ARGS[@]}" -display "${DISPLAY_TYPE}" -serial mon:stdio
    fi
    exec "${QEMU_BIN}" "${QEMU_ARGS[@]}" -nographic -serial mon:stdio
fi

if [[ ${#EXPECTS[@]} -eq 0 ]]; then
    EXPECTS=("buildroot login:")
fi
mkdir -p "$(dirname "${LOG_PATH}")"
: > "${LOG_PATH}"

log "smoke test: timeout ${TIMEOUT}s, expecting: ${EXPECTS[*]}"
log "UART log:   ${LOG_PATH}"

set +e
"${QEMU_BIN}" "${QEMU_ARGS[@]}" -nographic -serial mon:stdio -no-reboot >"${LOG_PATH}" 2>&1 &
QEMU_PID=$!
DEADLINE=$(( SECONDS + TIMEOUT ))
PASSED=0
PANIC_HIT=0
while kill -0 "${QEMU_PID}" 2>/dev/null; do
    if grep -q "Kernel panic - not syncing" "${LOG_PATH}" 2>/dev/null; then
        PANIC_HIT=1
        log "kernel panic detected, stopping early"
        break
    fi
    ALL_MATCHED=1
    for pat in "${EXPECTS[@]}"; do
        grep -qE -- "${pat}" "${LOG_PATH}" 2>/dev/null || { ALL_MATCHED=0; break; }
    done
    if [[ "${ALL_MATCHED}" -eq 1 ]]; then
        PASSED=1
        break
    fi
    if (( SECONDS >= DEADLINE )); then
        break
    fi
    sleep 1
done

QEMU_RC=0
if kill -0 "${QEMU_PID}" 2>/dev/null; then
    kill "${QEMU_PID}" 2>/dev/null
    wait "${QEMU_PID}" 2>/dev/null
    QEMU_RC=124
else
    wait "${QEMU_PID}"
    QEMU_RC=$?
fi
set -e

if [[ "${PANIC_HIT}" -eq 1 ]]; then
    log "FAIL: kernel panic (log: ${LOG_PATH})"
    tail -n 60 "${LOG_PATH}" >&2 || true
    exit 1
fi

if [[ "${QEMU_RC}" -ne 0 && "${QEMU_RC}" -ne 124 ]]; then
    log "FAIL: QEMU exited rc=${QEMU_RC} (log: ${LOG_PATH})"
    tail -n 60 "${LOG_PATH}" >&2 || true
    exit 1
fi

FAILED=0
for pat in "${EXPECTS[@]}"; do
    if grep -qE -- "${pat}" "${LOG_PATH}"; then
        log "PASS: matched '${pat}'"
    else
        log "FAIL: pattern not found: '${pat}'"
        FAILED=1
    fi
done

if [[ "${FAILED}" -ne 0 ]]; then
    log "last 60 lines of UART log:"
    tail -n 60 "${LOG_PATH}" >&2 || true
    exit 1
fi

log "smoke test PASS (log: ${LOG_PATH})"
