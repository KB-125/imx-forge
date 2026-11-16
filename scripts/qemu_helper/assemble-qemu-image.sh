#!/bin/bash
#
# assemble-qemu-image.sh - Assemble the partitioned SD/eMMC image for the
# U-Boot -> Linux -> Buildroot chain.
#
# The image builder expects a release directory laid out as:
#
#   <release-dir>/uboot/u-boot-dtb.imx
#   <release-dir>/linux/arch/arm/boot/zImage
#   <release-dir>/linux/arch/arm/boot/dts/nxp/imx/<dtb>.dtb
#   <release-dir>/rootfs/
#
# Our component builds live in out/uboot and out/linux, while Buildroot
# writes out/release-latest/rootfs.  This script links the two build trees
# into the release directory (without copying), then calls the normal image
# builder, which also writes /boot.scr and the 8 KiB U-Boot environment.
#
# Usage:
#   scripts/qemu_helper/assemble-qemu-image.sh \
#       [--release-dir=PATH] [--device-tree=NAME] \
#       [--boot-media=emmc|sd] [--image-size-mb=N] [--no-stage]
#
# Defaults: out/release-latest, imx6ull-aes, emmc, 128 MiB.
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
IMAGE_BUILDER="${PROJECT_ROOT}/scripts/image_builder/build_imx6ull_image.sh"
RELEASE_DIR="${PROJECT_ROOT}/out/release-latest"
DEVICE_TREE="imx6ull-aes"
BOOT_MEDIA="emmc"
IMAGE_SIZE_MB="128"
NO_STAGE=0

log() { echo "[assemble-image] $*"; }
die() { echo "[assemble-image] error: $*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^# Defaults:/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release-dir=*)   RELEASE_DIR="${1#*=}" ;;
        --release-dir)     shift; [[ $# -gt 0 ]] || die "--release-dir requires a value"; RELEASE_DIR="$1" ;;
        --device-tree=*)   DEVICE_TREE="${1#*=}" ;;
        --device-tree)     shift; [[ $# -gt 0 ]] || die "--device-tree requires a value"; DEVICE_TREE="$1" ;;
        --boot-media=*)    BOOT_MEDIA="${1#*=}" ;;
        --boot-media)      shift; [[ $# -gt 0 ]] || die "--boot-media requires a value"; BOOT_MEDIA="$1" ;;
        --image-size-mb=*) IMAGE_SIZE_MB="${1#*=}" ;;
        --image-size-mb)   shift; [[ $# -gt 0 ]] || die "--image-size-mb requires a value"; IMAGE_SIZE_MB="$1" ;;
        --no-stage)        NO_STAGE=1 ;;
        -h|--help)         usage ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

[[ -x "${IMAGE_BUILDER}" ]] || die "missing ${IMAGE_BUILDER}"
case "${BOOT_MEDIA}" in
    emmc|sd) ;;
    *) die "--boot-media must be emmc or sd, got: ${BOOT_MEDIA}" ;;
esac
[[ "${IMAGE_SIZE_MB}" =~ ^[0-9]+$ ]] || die "--image-size-mb must be an integer"
RELEASE_DIR="$(realpath -m "${RELEASE_DIR}")"

UBOOT_BIN="${PROJECT_ROOT}/out/uboot/u-boot-dtb.bin"
UBOOT_IMX="${PROJECT_ROOT}/out/uboot/u-boot-dtb.imx"
UBOOT_ELF="${PROJECT_ROOT}/out/uboot/u-boot"
MKIMAGE="${PROJECT_ROOT}/out/uboot/tools/mkimage"
KERNEL="${PROJECT_ROOT}/out/linux/arch/arm/boot/zImage"
DTB_FILE="${PROJECT_ROOT}/out/linux/arch/arm/boot/dts/nxp/imx/${DEVICE_TREE}.dtb"

[[ -f "${UBOOT_BIN}" ]] || die "U-Boot loader image missing: ${UBOOT_BIN} (run build-uboot.sh)"
[[ -f "${UBOOT_IMX}" ]] || die "U-Boot boot image missing: ${UBOOT_IMX} (run build-uboot.sh)"
[[ -f "${UBOOT_ELF}" ]] || die "U-Boot ELF missing: ${UBOOT_ELF}"
[[ -x "${MKIMAGE}" ]]   || die "mkimage missing: ${MKIMAGE}"
[[ -f "${KERNEL}" ]]    || die "kernel missing: ${KERNEL} (run build-linux.sh)"
[[ -f "${DTB_FILE}" ]]  || die "dtb missing: ${DTB_FILE} (run build-linux.sh)"
[[ -e "${RELEASE_DIR}/rootfs/bin/busybox" ]] \
    || die "rootfs missing or incomplete: ${RELEASE_DIR}/rootfs/bin/busybox (run build-rootfs.sh)"

link_build_tree() {
    local name="$1" target="$2"
    local link="${RELEASE_DIR}/${name}"
    local rel
    rel="$(realpath --relative-to="${RELEASE_DIR}" "${target}")"

    if [[ "${NO_STAGE}" -eq 1 ]]; then
        [[ -e "${link}" ]] || die "--no-stage given but ${link} does not exist"
        return 0
    fi

    mkdir -p "${RELEASE_DIR}"
    if [[ -L "${link}" ]]; then
        if [[ ! -e "${link}" ]]; then
            rm -f "${link}"
            ln -s "${rel}" "${link}"
            log "refreshed symlink ${link} -> ${rel}"
        fi
    elif [[ -e "${link}" ]]; then
        log "keeping existing ${link} (not a symlink)"
    else
        ln -s "${rel}" "${link}"
        log "linked ${link} -> ${rel}"
    fi
}

link_build_tree uboot "${PROJECT_ROOT}/out/uboot"
link_build_tree linux "${PROJECT_ROOT}/out/linux"

# The image builder reads the boot image and kernel/dtb through the release
# directory; verify the links resolve before doing the expensive work.
[[ -f "${RELEASE_DIR}/uboot/u-boot-dtb.imx" ]] || die "release uboot tree is incomplete: ${RELEASE_DIR}/uboot"
[[ -f "${RELEASE_DIR}/linux/arch/arm/boot/zImage" ]] || die "release linux tree is incomplete: ${RELEASE_DIR}/linux"

log "assembling ${BOOT_MEDIA} image (${IMAGE_SIZE_MB} MiB) from ${RELEASE_DIR}"
"${IMAGE_BUILDER}" \
    --release-dir="${RELEASE_DIR}" \
    --device-tree="${DEVICE_TREE}" \
    --boot-media="${BOOT_MEDIA}" \
    --image-size-mb="${IMAGE_SIZE_MB}"

IMAGE="${RELEASE_DIR}/images/$(basename "${DEVICE_TREE}" .dtb)-${BOOT_MEDIA}.img"
[[ -f "${IMAGE}" ]] || die "image builder finished but ${IMAGE} is missing"

log "image: ${IMAGE} ($(du -h "${IMAGE}" | awk '{print $1}'))"
log "boot the full chain with:"
cat <<EOF

  scripts/qemu_helper/run-qemu-uboot.sh --image=${IMAGE}

  # or, equivalently:
  ${PROJECT_ROOT}/out/qemu/build/qemu-system-arm -M mcimx6ul-evk -m 512M \
    -device loader,file=${UBOOT_BIN},addr=0x87800000,cpu-num=0 \
    -drive file=${IMAGE},if=sd,index=1,format=raw \
    -nographic -serial mon:stdio

EOF
