# run-qemu-uboot.sh - 在自编 QEMU 中跑 U-Boot → Linux → rootfs 全链

## 脚本概述

与 `run-qemu.sh` 的 `-kernel zImage -dtb` 直启不同，`run-qemu-uboot.sh` 走
完整启动链：

```text
QEMU generic loader (0x87800000)
  -> U-Boot (u-boot-dtb.bin)
    -> mmc 1:1 /boot.scr
      -> zImage + imx6ull-aes.dtb
        -> mmc 1:2 ext4 rootfs
          -> Buildroot login:
```

QEMU 的 `mcimx6ul-evk` 没有 i.MX boot ROM/HAB 模型，因此：

- 必须用 `-device loader,file=out/uboot/u-boot-dtb.bin,addr=0x87800000,cpu-num=0`
  载入**无 IVT 头**的 U-Boot；
- 不能 `-bios u-boot-dtb.imx`（QEMU 不解析 i.MX IVT，会当成无效 BIOS）。

## 用法

```bash
# 交互模式（默认）；Ctrl-A X 退出，Ctrl-A C 进 QEMU monitor
scripts/qemu_helper/run-qemu-uboot.sh

# 非交互冒烟：等 Buildroot login 提示，180s 超时，日志落 out/qemu/uboot-boot.log
scripts/qemu_helper/run-qemu-uboot.sh --smoke

# 自定义断言（可重复）
scripts/qemu_helper/run-qemu-uboot.sh --smoke \
    --expect='Linux version 7\.2\.' --expect='buildroot login:'

# 指定镜像/U-Boot；带显示（串口仍在 stdio）
scripts/qemu_helper/run-qemu-uboot.sh \
    --image=out/my-release/images/imx6ull-aes-sd.img --display=gtk
```

## 启动参数

```bash
out/qemu/build/qemu-system-arm -M mcimx6ul-evk -m 512M \
  -device loader,file=out/uboot/u-boot-dtb.bin,addr=0x87800000,cpu-num=0 \
  -drive file=out/release-latest/images/imx6ull-aes-emmc.img,if=sd,index=1,format=raw \
  -nographic -serial mon:stdio
```

- `-M mcimx6ul-evk`：QEMU 11.1 起的 i.MX6UL 板级模型（需本项目补丁系列）；
- `-m 512M`：与真板 DRAM 一致，U-Boot 打印 `DRAM: 512 MiB`；
- `if=sd,index=1`：U-Boot 侧对应 `mmc 1`，内核侧是 `/dev/mmcblk1`；
- `boot.scr` 里的 cmdline 使用 `root=/dev/mmcblk1p2 rootwait`。

## 冒烟判定

`--smoke` 后台启动 QEMU，每秒检查一次 UART 日志：

- 所有 `--expect` 都匹配 → PASS，exit 0；
- 出现 `Kernel panic - not syncing` → 立即 FAIL；
- 超时仍未匹配 → 打印日志尾部并 FAIL。

默认只要求 `buildroot login:`，即“U-Boot 已把控制权交给内核、内核挂载
rootfs 并启动 getty”。要验证登录，可交互运行后输入 `root`（无密码）再执行
`uname -a`。

## 前置条件

- `out/qemu/build/qemu-system-arm` 存在（`scripts/build_helper/build-qemu.sh`）；
- 镜像存在（`scripts/qemu_helper/assemble-qemu-image.sh`）；
- `out/uboot/u-boot-dtb.bin` 存在（`scripts/build_helper/build-uboot.sh`）。

任一缺失都会在启动前报错，不会静默用 stock QEMU 或旧镜像。

## 实测（2026-11-16）

`--smoke` 在 6 秒内匹配到 `buildroot login:`，UART 日志关键行：

```text
U-Boot 2026.10-dirty
DRAM:  512 MiB
MMC:   FSL_SDHC: 0, FSL_SDHC: 1
Linux version 7.2.9-dirty ... armv7l
mmcblk1: mmc1:0376 QEMU! 128 MiB
EXT4-fs (mmcblk1p2): mounted filesystem ...
buildroot login:
```

进一步用 `expect` 登录 root 验证：

```text
buildroot login: root
# uname -a
Linux buildroot 7.2.9-dirty #1 ... armv7l GNU/Linux
# cat /proc/cmdline
console=ttymxc0,115200 root=/dev/mmcblk1p2 rootwait rw
# poweroff -f
reboot: Power down
```

即 U-Boot → zImage/dtb（p1）→ ext4 rootfs（p2）→ login 全链闭合。
