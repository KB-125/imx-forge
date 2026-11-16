#!/usr/bin/env bash
# 生成四个组件的 compile_commands.json，并合并为 out/compile_commands.json。
#
#   QEMU     out/qemu/build/compile_commands.json   (meson 在 configure 时生成)
#   U-Boot   out/uboot/compile_commands.json        (scripts/gen_compile_commands.py)
#   Linux    out/linux/compile_commands.json        (make compile_commands.json)
#   BusyBox  out/busybox/compile_commands.json      (复用内核 gen_compile_commands.py)
#
# BusyBox 不在项目构建脚本里单独编译；本脚本若发现 out/busybox 未构建，会用
# rootfs/buildroot/fragments/busybox.config 的完整配置做一次树外构建。
#
# 用法:
#   scripts/build_helper/gen-compile-commands.sh
#   scripts/build_helper/gen-compile-commands.sh --allow-missing   # 缺组件时也生成
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CROSS_COMPILE="${CROSS_COMPILE:-arm-none-linux-gnueabihf-}"
CROSS_GCC=""
ALLOW_MISSING=0

log()  { printf '[gen-cc] %s\n' "$*"; }
die()  { printf '[gen-cc] error: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-missing) ALLOW_MISSING=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "unknown option: $1" ;;
    esac
    shift
done

command -v python3 >/dev/null || die "python3 not found"
command -v make >/dev/null    || die "make not found"

if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
    if [[ -x "/opt/arm-gnu-toolchain/bin/${CROSS_COMPILE}gcc" ]]; then
        export PATH="/opt/arm-gnu-toolchain/bin:${PATH}"
    else
        die "${CROSS_COMPILE}gcc not found (set CROSS_COMPILE or add the toolchain to PATH)"
    fi
fi
CROSS_GCC="$(command -v "${CROSS_COMPILE}gcc")"
log "cross compiler: ${CROSS_GCC}"

cd "${PROJECT_ROOT}"

# ---------------------------------------------------------------- QEMU -----
if [[ ! -f out/qemu/build/compile_commands.json ]]; then
    if [[ "${ALLOW_MISSING}" -eq 1 ]]; then
        log "QEMU database missing (out/qemu/build/compile_commands.json)"
    else
        die "QEMU database missing; run scripts/build_helper/build-qemu.sh first
     (meson writes compile_commands.json during configure)"
    fi
else
    log "QEMU database: out/qemu/build/compile_commands.json"
fi

# --------------------------------------------------------------- U-Boot ----
if [[ ! -d out/uboot ]]; then
    [[ "${ALLOW_MISSING}" -eq 1 ]] || die "out/uboot missing; run scripts/build_helper/build-uboot.sh first"
    log "U-Boot build directory missing, skipping"
else
    log "generating U-Boot database"
    python3 third_party/uboot-mainline/scripts/gen_compile_commands.py \
        -d "${PROJECT_ROOT}/out/uboot" \
        -o "${PROJECT_ROOT}/out/uboot/compile_commands.json"
fi

# ---------------------------------------------------------------- Linux ----
if [[ ! -f out/linux/.config ]]; then
    [[ "${ALLOW_MISSING}" -eq 1 ]] || die "out/linux/.config missing; run scripts/build_helper/build-linux.sh first"
    log "Linux build directory missing, skipping"
else
    log "generating Linux database (may re-run modules_prepare)"
    make -C third_party/linux_mainline \
        ARCH=arm CROSS_COMPILE="${CROSS_COMPILE}" \
        O="${PROJECT_ROOT}/out/linux" \
        compile_commands.json
fi

# -------------------------------------------------------------- BusyBox ----
if [[ ! -f out/busybox/busybox ]]; then
    if [[ "${ALLOW_MISSING}" -eq 1 ]]; then
        log "BusyBox build directory missing, skipping"
    else
        log "building BusyBox out-of-tree with the Buildroot fragment config"
        mkdir -p out/busybox
        make -C third_party/busybox O="${PROJECT_ROOT}/out/busybox" defconfig
        cp rootfs/buildroot/fragments/busybox.config out/busybox/.config
        # yes(1) may exit with SIGPIPE once oldconfig has read enough input.
        (yes "" | make -C third_party/busybox O="${PROJECT_ROOT}/out/busybox" oldconfig) || true
        make -C third_party/busybox O="${PROJECT_ROOT}/out/busybox" \
            CROSS_COMPILE="${CROSS_COMPILE}" -j"$(nproc)" -k
    fi
fi

if [[ -f out/busybox/busybox ]]; then
    log "generating BusyBox database"
    python3 third_party/linux_mainline/scripts/clang-tools/gen_compile_commands.py \
        -d "${PROJECT_ROOT}/out/busybox" \
        -o "${PROJECT_ROOT}/out/busybox/compile_commands.json"
fi

# ---------------------------------------------------------------- merge ----
merge_args=(--root "${PROJECT_ROOT}" --cross-gcc "${CROSS_GCC}")
if [[ "${ALLOW_MISSING}" -eq 1 ]]; then
    merge_args+=(--allow-missing)
fi
python3 "${SCRIPT_DIR}/merge-compile-commands.py" "${merge_args[@]}"
