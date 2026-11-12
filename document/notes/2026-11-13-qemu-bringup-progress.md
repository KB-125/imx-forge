---
title: QEMU 启动链 Bring-up 进度（U-Boot → Kernel → rootfs）
description: "路线 A′ 的逐阶段实测记录：补丁 backport、U-Boot 经 generic loader 启动、MMC/EXT4 验证，直至没有实物板卡也能在 QEMU 跑完整启动链"
---

<PageHeader icon="🧪" title="QEMU 启动链 Bring-up 进度" description="路线 A′ 的逐阶段实测记录：从补丁 backport 到 U-Boot 引导内核" />

> 关联文档：
> - [QEMU 运行定制 U-Boot / Kernel / rootfs 的可行性评估](2026-11-13-qemu-custom-system-feasibility.md)（结论与路线对比）
> - [A′ 方案评估：backport 上游 U-Boot 启动链补丁](2026-11-13-a-prime-backport-assessment.md)（补丁清单与门禁）

本文按 G0–G5 门禁逐步记录实测结果、命令与踩坑，每完成一个阶段更新一次。

## 0. 路线与目标

无实物板卡，在 QEMU `mcimx6ul-evk` 上跑通本仓库的定制启动链：

```
QEMU generic loader ──► U-Boot (TEXT_BASE=0x87800000)
                          │ 从 USDHC2 (mmc 1) 的 p1 读取 zImage + imx6ull-aes.dtb
                          ▼
                        Linux kernel ──► SD p2 rootfs ──► buildroot login
```

与真机的差异只有两处，其余与真机一致：

1. QEMU 没有 boot ROM/HAB，无法用 `-bios` 加载带 IVT/DCD 头的 `u-boot-dtb.imx`，改用 `-device loader` 直接把无头镜像投放到 `TEXT_BASE` 并置 PC。
2. QEMU 的 SD 模型接在 USDHC2 上（`-drive if=sd,index=1`），对应 guest 的 `mmc 1` → `/dev/mmcblk1`，与镜像构建脚本 `--boot-media=emmc` 的语义一致。

## 1. 阶段总览

| 门禁 | 内容 | 状态 | 结论 |
| --- | --- | --- | --- |
| G0 | QEMU v11.1.0 + 26 个补丁编译 | ✅ | `out/qemu/build/qemu-system-arm`，自报 11.1.0-dirty |
| G1 | loader 载 U-Boot，串口出 banner | ✅ | `U-Boot 2026.10-dirty`，进 `=>` 提示符 |
| G2 | U-Boot 正确识别 DRAM | ✅ | `DRAM: 512 MiB`（MMDC 几何模型生效） |
| G3 | U-Boot 识别 SD 卡与分区 | ✅ | `mmc list` 两个控制器；`mmc info` 128 MiB SD High Speed 4-bit |
| G4 | U-Boot 读 p1 ext4 | ✅ | `ext4ls`/`ext4load` 成功，`md` 校验内容一致 |
| G5 | 加载内核 + rootfs 到 login | ✅ | 串口出现 `buildroot login:`，root 登录、`uname`、`poweroff` 全部通过 |

## 2. G0：补丁入库与 QEMU 编译

### 2.1 补丁来源与入库

上游系列 [PATCH 00/10] *hw/arm: Enable U-Boot boot on MCIMX6UL-EVK*（Bin Meng，2026-08-12）不能直接叠在本仓库已有的 16 个补丁上，因此按 v11.1.0 重新 rebase：

- 先在 `third_party/qemu` 上应用仓库原有 0001–0016（提交 baseline `bf8fc51`）；
- 再逐个应用上游 p01–p10，只有 04（MMDC 几何模型）因三个文件的上下文被既有补丁改动而冲突，按下列方式解决：
  - `hw/arm/fsl-imx6ul.c`：在 `fsl_imx6ul_properties[]` 末尾追加 `DEFINE_PROP_UINT64("ram-size", FslIMX6ULState, ram_size, 128 * MiB)`；
  - `hw/arm/mcimx6ul-evk.c`：在 `qdev_realize()` 前调用 `object_property_set_uint(OBJECT(s), "ram-size", machine->ram_size, &error_fatal)`；
  - `include/hw/arm/fsl-imx6ul.h`：补 `MemoryRegion mmdc;` 与 `uint64_t ram_size;`。
- 逐个 `git commit` 后 `git format-patch bf8fc51..HEAD` 导出，diffstat 与上游 cover letter 完全一致（315 insertions / 22 deletions）。

最终库存放为 `patches/qemu/0017…0026`，原始邮件与说明保存在 `patches/qemu/uboot-boot-chain/`（`p00.patch`–`p10.patch` + `README.md`）。

在 v11.1.0 上验证：16 + 10 = 26 个补丁全部干净应用，`22 files changed, 530 insertions(+), 32 deletions(-)`。

### 2.2 无 root 构建环境

宿主机无 sudo 权限，依赖全部解包到 `/tmp/qdeps`，Python 包解到 `/tmp/pylibs`：

```bash
mkdir -p /tmp/qdeps /tmp/dl
cd /tmp/dl
apt-get download pkg-config pkgconf pkgconf-bin libpkgconf3 ninja-build \
    libglib2.0-dev libpixman-1-dev libfdt-dev zlib1g-dev libpcre2-dev \
    libffi-dev libmount-dev libselinux1-dev uuid-dev libslirp-dev \
    python3-venv python3.12-venv
for d in *.deb; do dpkg-deb -x "$d" /tmp/qdeps; done

# meson >= 1.5（Ubuntu 24.04 只有 1.3.2）
curl -sSLo /tmp/get-pip.py https://bootstrap.pypa.io/get-pip.py
python3 /tmp/get-pip.py -q --target /tmp/pylibs
PYTHONPATH=/tmp/pylibs python3 -m pip install -q --target /tmp/pylibs 'meson>=1.5'
```

两个必须修的坑：

1. `.pc` 文件里的 `prefix=/usr` 会让 pkg-config 生成 `/usr/include` 的编译参数，而实际头文件在 `/tmp/qdeps/usr/include`，表现为误导性的 `sizeof(size_t) doesn't match GLIB_SIZEOF_SIZE_T`。批量改写 `prefix` 为 `/tmp/qdeps/usr` 即可。
2. 系统缺 `ensurepip`，QEMU 的 `mkvenv` 建 venv 会报 `ERROR: python venv creation failed`；运行时带上 `PYTHONPATH=/tmp/pylibs` 让 mkvenv 找得到 pip/setuptools，它会退化为 non-isolated venv。

### 2.3 编译命令

```bash
cat > /tmp/build-qemu-run.sh <<'EOF'
#!/bin/bash
set -eo pipefail
cd /home/liyiming/learning/Linux/imx-forge
export PATH=/tmp/qdeps/usr/bin:/tmp/pylibs/bin:$PATH
export PYTHONPATH=/tmp/pylibs
export PKG_CONFIG_PATH=/tmp/qdeps/usr/lib/x86_64-linux-gnu/pkgconfig:/tmp/qdeps/usr/share/pkgconfig
export LD_LIBRARY_PATH=/tmp/qdeps/usr/lib/x86_64-linux-gnu
export CFLAGS="-I/tmp/qdeps/usr/include"
export LDFLAGS="-L/tmp/qdeps/usr/lib/x86_64-linux-gnu"
export LIBRARY_PATH=/tmp/qdeps/usr/lib/x86_64-linux-gnu
git -C third_party/qemu checkout -- .
git -C third_party/qemu clean -fdq
rm -rf out/qemu
exec ./scripts/build_helper/build-qemu.sh --jobs=32
EOF
chmod +x /tmp/build-qemu-run.sh
/tmp/build-qemu-run.sh
```

结果：

```
[3185/3185] Linking target tests/fp/fp-bench
[build-qemu] done: .../out/qemu/build/qemu-system-arm
             (QEMU emulator version 11.1.0 (v11.1.0-dirty))
```

> 注意：每次重编前必须 `git clean -fdq`，否则上次失败残留的 untracked 新文件会让 0003 补丁报「已经存在于工作区中」。

## 3. G1 / G2：generic loader 启动 U-Boot

```bash
timeout 25 out/qemu/build/qemu-system-arm \
  -M mcimx6ul-evk -m 512M \
  -device loader,file=out/uboot/u-boot-dtb.bin,addr=0x87800000,cpu-num=0 \
  -nographic -serial mon:stdio
```

实测输出：

```
U-Boot 2026.10-dirty (Nov 13 2026 - 01:35:10 +0800)

CPU:   Freescale i.MX6UL rev1.0 at 1188MHz
CPU:   Commercial temperature grade (0C to 95C)
Reset cause: POR
Model: Awesome Embedded Studio IMX6ULL (i.mx NXP)
Awesome Embedded Studio Authored
DRAM:  512 MiB
Core:  78 devices, 21 uclasses, devicetree: separate
MMC:   FSL_SDHC: 0, FSL_SDHC: 1
Loading Environment from MMC... Card did not respond to voltage select! : -110
*** Warning - No block device, using default environment

In:    serial
Out:   serial
Err:   serial
Net:   eth1: ethernet@20b4000 [PRIME], eth0: ethernet@2188000
=>
```

结论：

- **G1 通过**：未改动的 U-Boot proper 直接在 QEMU 上跑起来，说明 SCU 兼容窗口、PMU_MISC0 复位值、早期寄存器占位这三类补丁有效。
- **G2 通过**：`DRAM: 512 MiB` 与 `-m 512M` 一致，说明 MMDC 几何模型 + `imx_ddr_size()` 的 29 位推导闭环。**不需要**再给 U-Boot 加 `ram_size` workaround。
- `Card did not respond` 是预期现象：此时没有挂 SD 卡。
- `rngc_probe error = -19`（无 DCP RNG 模型）与 `Get shared mii bus` 属无害噪声。

## 4. G3 / G4：MMC 与 ext4 读取

先用一个 128 MiB（2 的幂）的测试镜像验证块设备链路，p1 从 16 MiB 开始、64 MiB ext4：

```bash
cd /tmp && rm -f g3.img && truncate -s 128M g3.img
printf 'label: dos\nstart=32768, size=131072, type=83\n' | sfdisk -q g3.img
truncate -s 64M p1.ext4 && mke2fs -q -t ext4 -d p1mnt -F p1.ext4
dd if=p1.ext4 of=g3.img bs=1M seek=16 conv=notrunc status=none
```

启动并交互：

```bash
out/qemu/build/qemu-system-arm -M mcimx6ul-evk -m 512M \
  -device loader,file=out/uboot/u-boot-dtb.bin,addr=0x87800000,cpu-num=0 \
  -drive file=/tmp/g3.img,if=sd,index=1,format=raw \
  -nographic -serial mon:stdio
```

```
=> mmc list
FSL_SDHC: 0
FSL_SDHC: 1 (SD)
=> mmc dev 1
switch to partitions #0, OK
mmc1 is current device
=> mmc info
Device: FSL_SDHC
Name: QEMU!
Bus Speed: 49500000
Mode: SD High Speed (50MHz)
Capacity: 128 MiB
Bus Width: 4-bit
=> ext4ls mmc 1:1 /
       14   README.txt
=> ext4load mmc 1:1 0x82000000 /README.txt
14 bytes read in 23 ms
=> md 0x82000000 4
82000000: 6c6c6568 72662d6f 702d6d6f 00000a31  hello-from-p1...
```

结论：

- **G3 通过**：uSDHC 的两个控制器都枚举成功，SD 卡识别为 128 MiB / High Speed / 4-bit。补丁 05–08（no-busy IRQ 位、vendor clock gates、status enables、SDMA 边界）在真实读写路径上生效。
- **G4 通过**：`ext4ls` 与 `ext4load` 均成功，`md` 校验内容正确。
- `Loading Environment from MMC ... bad CRC, using default environment` 属预期：镜像暂未写 U-Boot 环境区（`CONFIG_ENV_OFFSET=0x400000`，env 设备 index 1）。
- 新增的 `cyclic function video_idle took too long` 是 U-Boot 的 LCD 刷新函数在 QEMU 上节流不足，仅告警，不影响功能。

## 5. G5：内核 + rootfs（已跑通）

### 5.1 内核构建

```bash
cat > /tmp/build-linux-run.sh <<'EOF'
#!/bin/bash
set -eo pipefail
cd /home/liyiming/learning/Linux/imx-forge
export PATH=/opt/arm-gnu-toolchain/bin:/tmp/pylibs/bin:$PATH
export FORGE_PROGRESS_DISABLE=1
export PYTHONPATH=/tmp/pylibs
exec ./scripts/build_helper/build-linux.sh "$@"
EOF
chmod +x /tmp/build-linux-run.sh
/tmp/build-linux-run.sh
```

脚本会先把 `driver/device_tree/alpha-board/linux/imx6ull-aes.dts{,i}` 拷进内核树、把 `${FIRMWARE_DIR}` 替换进 defconfig 模板，产物在 `out/linux/arch/arm/boot/zImage` 与 `.../dts/nxp/imx/imx6ull-aes.dtb`。

### 5.2 rootfs 构建

```bash
export PATH=/opt/arm-gnu-toolchain/bin:$PATH
FORGE_PROGRESS_DISABLE=1 ./scripts/build_helper/build-buildroot.sh
```

产物目录 `out/release-latest/rootfs/`（Buildroot 2026.02 + br2-external，busybox / glibc / ALSA）。

### 5.3 镜像组装与启动（已完成）

```bash
# 按真机布局组装（U-Boot 写 1KiB 偏移，p1 从 16MiB 起放 zImage + dtb，p2 放 rootfs）
./scripts/image_builder/build_imx6ull_image.sh \
  --release-dir=out/release-latest --device-tree=imx6ull-aes \
  --boot-media=emmc --image-size-mb=128

out/qemu/build/qemu-system-arm -M mcimx6ul-evk -m 512M \
  -device loader,file=out/uboot/u-boot-dtb.bin,addr=0x87800000,cpu-num=0 \
  -drive file=out/release-latest/images/imx6ull-aes-emmc.img,if=sd,index=1,format=raw \
  -nographic -serial mon:stdio
```

产物：`out/release-latest/images/imx6ull-aes-emmc.img`（128 MiB，p1 64 MiB @16 MiB，p2 40 MiB），附 `.sha256` 与 `.manifest`。

U-Boot 侧流程（与 `boot.cmd` 一致，`CONFIG_BOOTDELAY=-1` 且 `CONFIG_BOOTCOMMAND` 是占位 echo，所以实测时手工下发）：

```
ext4load mmc 1:1 ${loadaddr} /zImage
ext4load mmc 1:1 ${fdt_addr_r} /imx6ull-aes.dtb
bootz ${loadaddr} - ${fdt_addr_r}
```

### 5.4 实测结果

```
=> ext4load mmc 1:1 0x82000000 /zImage
9260808 bytes read in 14752 ms (612.3 KiB/s)
=> ext4load mmc 1:1 0x83000000 /imx6ull-aes.dtb
35519 bytes read in 87 ms (398.4 KiB/s)
=> bootz 0x82000000 - 0x83000000
Kernel image @ 0x82000000 [ 0x000000 - 0x8d4f08 ]
## Flattened Device Tree blob at 83000000
   Booting using the fdt blob at 0x83000000
Starting kernel ...

[    0.000000] Booting Linux on physical CPU 0x0
[    0.000000] Linux version 7.2.9-dirty ...
[    2.263434] mmcblk1: mmc1:a83f QEMU! 128 MiB
[    2.277227]  mmcblk1: p1 p2
[    2.446034] EXT4-fs (mmcblk1p2): mounted filesystem ... r/w
[    2.469957] Run /sbin/init as init process
[    5.900944] random: crng init done

buildroot login: root
# uname -a
Linux buildroot 7.2.9-dirty #1 ... armv7l GNU/Linux
# ls /
bin dev etc home lib lib32 linuxrc media mnt opt proc root run sbin sys tmp usr var
# poweroff -f
reboot: Power down
```

- 串口在 U-Boot 阶段 <1 s 出 banner；zImage 的 9.26 MB 经 U-Boot ext4 读取约 2.0 s（4.4 MiB/s，见 5.6 的计时修复），内核从 `Starting kernel` 到 `buildroot login:` 约 6 s，整链约 19–20 s。
- 登录后 `uname -a`、`ls /`、`poweroff -f` 均正常，`poweroff` 能干净退出 QEMU（rc=0）。
- 内核启动期间的外设探测失败（`mxs-dma -110`、`spi-nor -110`、`Goodix-TS -110`、`pxp -110`、`mxs-dcp -110`、`wm8960 -22`、`imx_thermal -EINVAL`、`ocotp regmap` 缺失）与既有调研笔记一致，属于 QEMU 模型缺口，不影响启动链。

### 5.5 待观察的风险

| 编号 | 风险 | 现状 |
| --- | --- | --- |
| R1 | `fsl_esdhc` 取 `sdhc_clk` 为 0 导致卡初始化失败 | G3 已实测通过，排除 |
| R2 | 设备树 `usdhc2` 是 non-removable eMMC，QEMU 是 SD 卡 | G5 已验证：mmc1 枚举、p1 ext4 读、p2 挂 rootfs 全部正常 |
| R3 | 板级 dts 无 `aliases`，mmc 编号靠探测顺序 | 实测为 0=USDHC1、1=USDHC2，符合预期 |
| R4 | 新 U-Boot 访问 WDOG/GPC/SRC 未建模寄存器挂死 | 未触发 |
| R5 | 内核 dts 与 QEMU 模型不符 | 待内核启动后确认；必要时先用 EVK dtb 对照 |
| R6 | LCD 相关 cyclic 告警影响启动时序 | 已随 5.6 的计时修复消失：告警源于时间基准快 7.8 倍，而非 LCD 本身 |

### 5.6 自动启动、环境区与计时修复

三项遗留改进（自动启动、环境区固化、读取偏慢）已全部落地，并用无人值守启动验证：从 QEMU 冷启动到 `buildroot login:` 约 19–20 s，全程无需手工输入。

#### 5.6.1 计时 7.8 倍偏差（“读取偏慢”的真相）

现象：`ext4load` 读 9.26 MB 打印 `15883 ms (569.3 KiB/s)`，但墙钟只有约 2.0 s；同时 `cyclic function video_idle took too long: 11765us vs 5000us max` 的告警也不合理。

根因链：
- U-Boot 用 `CONFIG_SYSCOUNTER_TIMER=y`（`arch/arm/mach-imx/syscounter.c`），时间基准来自 ARM generic timer；
- `timer_init()` 用 `mcr p15, 0, %0, c14, c0, 0` 把 `CNTFRQ` 写成 `CFG_SC_TIMER_CLK`（`include/configs/mx6_common.h:12` = 8 MHz），`get_tbclk()` 再用 `mrc` 读回；
- QEMU 的 `CNTFRQ` 是 reads-as-written（`target/arm/helper.c:2066-2078`），而计数器实际速率由 `cpu->gt_cntfrq_hz` 决定；Cortex-A7 走 `ARM_FEATURE_BACKCOMPAT_CNTFRQ`，默认 62.5 MHz；
- 62.5 / 8 = 7.8125，与观测到的 15883 / 2040 ≈ 7.79 一致。于是 U-Boot 的 `get_timer()`、bootdelay、cyclic 阈值全部快约 7.8 倍。

修复：新增 `patches/qemu/0027-hw-arm-fsl-imx6ul-Program-the-generic-timer-at-8-MHz.patch`，在 `hw/arm/fsl-imx6ul.c` 的 CPU realize 之前执行 `qdev_prop_set_uint64(DEVICE(&s->cpu), "cntfrq", 8000000);`，让计数器与 guest 读到的 CNTFRQ 一致。重建后同一镜像打印 `9260808 bytes read in 2004 ms (4.4 MiB/s)`，与墙钟吻合；`video_idle took too long` 告警也消失。实测吞吐约 4.4–4.6 MiB/s（受 SD 模型与 ext4 限制），读取本身并不慢。

#### 5.6.2 自动启动

- `configs/mx6ull_aes_emmc_defconfig`：`CONFIG_BOOTDELAY=2`；`CONFIG_BOOTCOMMAND="if ext4load mmc 1:1 ${loadaddr} /boot.scr; then source ${loadaddr}; else if ext4load mmc 0:1 ${loadaddr} /boot.scr; then source ${loadaddr}; fi; fi"`；显式 `CONFIG_CMD_SOURCE=y`。
- 板级 `include/configs/mx6ull_aes_emmc.h` 增加 `"loadaddr=0x82000000\0"`。原先只定义了 `fdt_addr=0x83000000`，`loadaddr` 不存在，boot.scr 路径展开成空地址，实测会打印 `ext4load` 的 Usage。
- `scripts/image_builder/build_imx6ull_image.sh`：用 `out/uboot/tools/mkimage -A arm -O linux -T script -C none` 把 `/boot.cmd` 编译成 `/boot.scr` 写入 p1（同时保留 `/boot/boot.cmd`），`boot.cmd` 的 FDT 变量同步改为 `${fdt_addr}`。

#### 5.6.3 环境区固化

`CONFIG_ENV_OFFSET=0x400000`、`CONFIG_ENV_SIZE=0x2000`。镜像脚本新增 `create_env_image()`：

1. 用 `readelf -sW out/uboot/u-boot` 找到 `default_environment` 符号（0x878666bf，2770 字节，内含 `CONFIG_BOOTCOMMAND`）；
2. 用 `readelf -lW` 把符号虚拟地址映射到 ELF 文件偏移；
3. 取 2770 字节、补零到 8188 字节，前置 `zlib.crc32` 小端值，得到 8 KiB 合法环境镜像，dd 到镜像 0x400000。

启动日志由 `bad CRC, using default environment` 变为 `Loading Environment from MMC... OK`。

为什么不是用 `mkenvimage` 只写 `bootcmd`：U-Boot 从 MMC 导入环境时会整体替换默认环境，只写 `bootcmd` 会让 `loadaddr`/`fdt_addr` 等默认变量全部丢失（实测 `printenv loadaddr` → `not defined`，bootcmd 里 `${loadaddr}` 展开为空，`ext4load` 打印 Usage）。必须写入完整的默认环境。

#### 5.6.4 验证

```
Loading Environment from MMC... OK
Hit any key to stop autoboot: 2 ... 0
258 bytes read in 2 ms
9260808 bytes read in 2004 ms (4.4 MiB/s)
35519 bytes read in 9 ms
[    0.000000] Booting Linux on physical CPU 0x0
...
buildroot login:            # 全程无输入，约 19–20 s
```

改动文件：`patches/qemu/0027-*.patch`（QEMU 计时）、`scripts/image_builder/build_imx6ull_image.sh`（boot.scr + 环境镜像）、`patches/uboot-mainline/charlies_board.patch`（重新导出，含 defconfig 与头文件改动；已用干净 worktree 验证 13 个文件可应用、与工作区逐字节一致）。

## 6. 复现命令速查

```bash
# 1) QEMU（已完成）
/tmp/build-qemu-run.sh

# 2) U-Boot（已完成）
export PATH=/tmp/fakebin:/opt/arm-gnu-toolchain/bin:$PATH
FORGE_PROGRESS_DISABLE=1 PYTHONPATH=/tmp/pylibs ./scripts/build_helper/build-uboot.sh

# 3) 内核
/tmp/build-linux-run.sh

# 4) rootfs
export PATH=/opt/arm-gnu-toolchain/bin:$PATH
FORGE_PROGRESS_DISABLE=1 ./scripts/build_helper/build-buildroot.sh

# 5) 镜像 + 启动
./scripts/image_builder/build_imx6ull_image.sh --release-dir=out/release-latest \
  --device-tree=imx6ull-aes --boot-media=emmc
out/qemu/build/qemu-system-arm -M mcimx6ul-evk -m 512M \
  -device loader,file=out/uboot/u-boot-dtb.bin,addr=0x87800000,cpu-num=0 \
  -drive file=out/release-latest/images/imx6ull-aes-emmc.img,if=sd,index=1,format=raw \
  -nographic -serial mon:stdio
```

> 注：`/tmp/fakebin/convert` 是 Pillow 写的 ImageMagick 垫片（把 logo PNG 转成 8bpp BMP），用于在无 root 机器上满足 `logo_helper.sh`；有 ImageMagick 的环境可忽略。
>
> 镜像脚本会自动生成 `/boot.scr` 与 8 KiB 环境区（`ENV_OFFSET=0x400000`），因此上面的启动命令无需再手工 `ext4load`/`bootz`；`--boot-media=sd` 时 bootcmd 会自动回退到 `mmc 0:1`。

## 7. 结论

路线 A′ 已在 QEMU 上端到端跑通，U-Boot 只改了板级 defconfig 与板级环境头文件，**没有 ram_size workaround**：

1. QEMU v11.1.0 + 27 个补丁（项目 16 + 上游 U-Boot 启动链 10 + 计时修复 1）编译通过；
2. 无 boot ROM 的 QEMU 用 `-device loader` 直接启动 U-Boot proper，`DRAM: 512 MiB` 与 `-m 512M` 精确一致；
3. U-Boot 从 USDHC2（`mmc 1`）的 ext4 分区读取 `zImage` + `imx6ull-aes.dtb`，`bootz` 成功；
4. Linux 7.2.9 挂载同一 SD 卡的 p2 rootfs，busybox init 起 getty，`buildroot login:` 可登录并可 `poweroff` 干净退出。

曾列入的三项遗留改进已在 5.6 全部完成：自动启动（`boot.scr` + 真实 `bootcmd`）、环境区固化（默认环境 + 正确 CRC）、读取“偏慢”（实为计时快 7.8 倍，已由 QEMU 补丁 0027 修正，真实吞吐约 4.4 MiB/s）。

仍未处理、但不影响启动链的项：

- 内核启动期间的外设探测失败（mxs-dma / spi-nor / Goodix / pxp / dcp / wm8960 / imx_thermal）属于 QEMU 模型缺口；
- SD 读取吞吐约 4.5 MiB/s，若要继续提速需改 QEMU sdhci 的 SDMA 实现，而不是 U-Boot。
