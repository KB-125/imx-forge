#!/bin/bash
#
# build-rootfs.sh - Build the Buildroot rootfs used by the QEMU boot chain.
#
# This is a thin, opinionated wrapper around
# scripts/build_helper/build-buildroot.sh:
#   * adds the Arm GNU toolchain to PATH when it is not already there;
#   * refuses to start without a cross compiler;
#   * verifies the resulting rootfs contains bin/busybox.
#
# The U-Boot -> kernel -> rootfs chain needs a real rootfs tree at
# out/release-latest/rootfs.  The standalone out/busybox/busybox binary is
# not a rootfs; Buildroot supplies libc, init scripts, getty and the login
# prompt.
#
# Usage:
#   scripts/qemu_helper/build-rootfs.sh [--clean] [--reconfigure]
#
# Any other option is forwarded to build-buildroot.sh, for example:
#   scripts/qemu_helper/build-rootfs.sh --output-dir=out/my-buildroot
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
BUILDROOT_SH="${PROJECT_ROOT}/scripts/build_helper/build-buildroot.sh"
TOOLCHAIN_BIN="/opt/arm-gnu-toolchain/bin"
DEFAULT_ROOTFS="${PROJECT_ROOT}/out/release-latest/rootfs"

log() { echo "[build-rootfs] $*"; }
die() { echo "[build-rootfs] error: $*" >&2; exit 1; }

[[ -x "${BUILDROOT_SH}" ]] || die "missing ${BUILDROOT_SH}"

if ! command -v arm-none-linux-gnueabihf-gcc >/dev/null 2>&1; then
    [[ -d "${TOOLCHAIN_BIN}" ]] || die "cross compiler not in PATH and ${TOOLCHAIN_BIN} does not exist"
    export PATH="${TOOLCHAIN_BIN}:${PATH}"
fi
command -v arm-none-linux-gnueabihf-gcc >/dev/null 2>&1 \
    || die "arm-none-linux-gnueabihf-gcc not found (install the Arm GNU toolchain)"

# Parse just enough to know whether this invocation actually builds a rootfs.
SKIP_VERIFY=0
ROOTFS_DIR="${DEFAULT_ROOTFS}"
prev=""
for arg in "$@"; do
    case "${prev}" in
        --release-rootfs) ROOTFS_DIR="$arg" ;;
    esac
    case "${arg}" in
        --clean|--source-only|-h|--help) SKIP_VERIFY=1 ;;
        --release-rootfs=*) ROOTFS_DIR="${arg#*=}" ;;
    esac
    prev="${arg}"
done

log "toolchain: $(command -v arm-none-linux-gnueabihf-gcc)"
log "rootfs:    ${ROOTFS_DIR}"
log "running build-buildroot.sh $*"

FORGE_PROGRESS_DISABLE="${FORGE_PROGRESS_DISABLE:-1}" \
    "${BUILDROOT_SH}" "$@"

if [[ "${SKIP_VERIFY}" -eq 1 ]]; then
    log "non-build invocation finished (rootfs not verified)"
    exit 0
fi

if [[ ! -e "${ROOTFS_DIR}/bin/busybox" ]]; then
    die "rootfs looks incomplete: ${ROOTFS_DIR}/bin/busybox not found"
fi

size="$(du -sh "${ROOTFS_DIR}" | awk '{print $1}')"
log "done: ${ROOTFS_DIR} (${size}, busybox present)"
log "next: scripts/qemu_helper/assemble-qemu-image.sh"
