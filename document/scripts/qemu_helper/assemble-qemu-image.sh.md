# assemble-qemu-image.sh - 组装 QEMU 全链的 SD/eMMC 镜像

## 脚本概述

`build_imx6ull_image.sh` 要求 release 目录下同时有 U-Boot、Linux 和 rootfs：

```text
out/release-latest/
├── uboot/u-boot-dtb.imx
├── linux/arch/arm/boot/zImage
├── linux/arch/arm/boot/dts/nxp/imx/imx6ull-aes.dtb
└── rootfs/
```

本项目的组件构建产物分别位于 `out/uboot` 和 `out/linux`，而 Buildroot 把
rootfs 写到 `out/release-latest/rootfs`。`assemble-qemu-image.sh` 用相对符号
链接把前两者接进 release 目录（不复制），然后调用标准镜像组装脚本。

镜像布局与真板一致：

| 分区 | 内容 |
|---|---|
| p1 (ext4, label `BOOT`) | `zImage`、`imx6ull-aes.dtb`、`boot.scr`（U-Boot 用 `ext4load` 读取） |
| p2 (ext4) | Buildroot rootfs |
| 头部 | 8 KiB U-Boot 环境（`fw_env.config` 指向 eMMC/SD 偏移） |

## 用法

```bash
# 默认：out/release-latest + imx6ull-aes + emmc + 128 MiB
scripts/qemu_helper/assemble-qemu-image.sh

# 改镜像大小 / 启动介质
scripts/qemu_helper/assemble-qemu-image.sh --image-size-mb=256 --boot-media=sd

# 已经手工摆好 release 目录时，不创建链接
scripts/qemu_helper/assemble-qemu-image.sh --no-stage

# 自定义 release 目录
scripts/qemu_helper/assemble-qemu-image.sh --release-dir=out/my-release
```

产物：`out/release-latest/images/imx6ull-aes-emmc.img`，并打印可直接运行的
QEMU 命令。

## 前置条件

- `out/uboot/` 已由 `build-uboot.sh` 生成（需要 `.bin`、`.imx`、ELF、mkimage）；
- `out/linux/` 已由 `build-linux.sh` 生成（zImage + imx6ull-aes.dtb）；
- `out/release-latest/rootfs/bin/busybox` 已由 `build-rootfs.sh` 生成。

缺任何一项都会在真正组装前报错，并给出对应的生成命令。

## 符号链接说明

`out/release-latest/uboot -> ../uboot`、`linux -> ../linux` 是相对链接，移动
整个 `out/` 或换机器后仍然有效。如果 release 目录里已经有同名真实目录，
脚本保留不动，只检查其中的必需文件。

## 实测（2026-11-16）

- rootfs 32 MiB → 镜像 106 MiB；
- 布局：U-Boot @1 KiB、env @4096 KiB、p1 64 MiB @16 MiB、p2 40 MiB @80 MiB；
- SHA256 记录在同名 `.sha256` 文件（2026-11-16 重建为
  `c5320b9d086ea22a04e2a56963c7eb6cba04ab454b1e5be9f6f3e15f6195dc00`）；
- manifest 记录 bootfiles、env、autoboot 与手工 U-Boot 启动命令。
