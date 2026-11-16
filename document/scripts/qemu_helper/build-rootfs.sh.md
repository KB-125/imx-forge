# build-rootfs.sh - 构建 QEMU 全链所需的 Buildroot rootfs

## 脚本概述

`build-rootfs.sh` 是 `scripts/build_helper/build-buildroot.sh` 的薄封装，专门
服务于 QEMU 全链启动（U-Boot → Linux → rootfs）。它做三件事：

1. 如果交叉工具链不在 `PATH`，自动加入 `/opt/arm-gnu-toolchain/bin`；
2. 没有 `arm-none-linux-gnueabihf-gcc` 时直接报错，避免 Buildroot 中途才失败；
3. 构建完成后检查 `out/release-latest/rootfs/bin/busybox` 是否存在。

单独编出来的 `out/busybox/busybox` 只是 BusyBox 可执行文件，不是 rootfs；
全链需要 Buildroot 提供的 libc、`/init`、getty 和 login 提示符。

## 用法

```bash
# 默认：defconfig + make，产物到 out/release-latest/rootfs
scripts/qemu_helper/build-rootfs.sh

# 只清理 Buildroot 输出后退出
scripts/qemu_helper/build-rootfs.sh --clean

# 强制重新 defconfig
scripts/qemu_helper/build-rootfs.sh --reconfigure

# 把其余参数原样透传给 build-buildroot.sh
scripts/qemu_helper/build-rootfs.sh --output-dir=out/my-buildroot
```

## 产物与时间

| 产物 | 说明 |
|---|---|
| `out/release-latest/rootfs/` | rootfs 目录树，含 `bin/busybox`、`/init`、getty、login |
| `out/release-latest/buildroot/` | Buildroot 的 `O=` 输出目录与构建日志 |

默认最小 rootfs 约 15 分钟（32 核）；Qt6 配置会到 2–4 小时。首次构建需要从
网络下载 Buildroot 包，GitHub Release 资源不可达时 Buildroot 会回退到
`sources.buildroot.net`，也可以把 tarball 预放到 `third_party/buildroot/dl/`。

## 与其他脚本的关系

```bash
scripts/qemu_helper/build-rootfs.sh          # 1. rootfs 目录树
scripts/qemu_helper/assemble-qemu-image.sh   # 2. 组装分区镜像
scripts/qemu_helper/run-qemu-uboot.sh        # 3. QEMU 全链启动
```

`build-rootfs.sh` 不编内核和 U-Boot；它们分别由
`scripts/build_helper/build-linux.sh`、`build-uboot.sh` 生成。

## 实测（2026-11-16）

- Buildroot 2026.02 + `imx6ull_aes_defconfig`，默认最小 rootfs；
- 首次构建约 11 分钟（32 核），产物 `out/release-latest/rootfs` 32 MiB；
- `rootfs/bin/busybox` 1.2 MiB，`getty`/login 正常；
- 网络受限时 Buildroot 会回退到 `sources.buildroot.net`；zstd/ccache 等
  GitHub Release 资源也可预放到 `third_party/buildroot/dl/<pkg>/`。
