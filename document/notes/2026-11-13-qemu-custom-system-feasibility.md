---
title: QEMU 运行定制 U-Boot / Kernel / rootfs 的可行性评估
description: "无实物板卡时 QEMU 能验证到哪一层：直启链路、U-Boot 启动链的三道硬阻断，以及 v11.2.0-rc0 的核查结果"
---

# 结论

| 目标 | 结论 | 关键依据 |
| --- | --- | --- |
| **内核 + rootfs 启动到登录提示符** | ✅ 可行（成功率 >95%） | 2026-08 Phase 0 已完整跑通；CI `qemu-smoke` 每次构建验证 |
| **定制 U-Boot 启动链** | ❌ 当前不可行 | QEMU 无 boot ROM/DCD、无 MMDC 模型；上游修复系列未进 v11.2.0-rc0 |
| **外设（LCD/触摸/传感器/CAN）** | ⚠️ 部分可行 | 依赖本仓库自建的 16 个 QEMU 补丁；ADC/音频/PMIC/eMMC boot 分区仍缺 |

一句话：**QEMU 可以替代「内核 + 用户空间 + 部分外设」的验证，但替代不了 U-Boot 启动链。** 后者缺的是 QEMU 侧的硬件模型，不是配置问题。

本文记录 2026-11-13 的评估结论与上游核查过程，仓库状态为 `third_party/qemu` v11.1.0、内核 v7.2.9、buildroot 2026.02。上游后续若有变化（尤其 v11.2 正式版或后续 rc），需要复核第 5 节。

## 1. 评估对象

- **板卡**：i.MX6ULL AES（正点原子 ALPHA 衍生），512 MB DDR @ `0x80000000`，eMMC 启动，板载 QSPI/传感器等外设。
- **仓库**：imx-forge，构建体系为「U-Boot / Linux / rootfs 三条 helper 脚本 + 镜像组装」。
- **目标**：无实物板卡时，按 `document/tutorial/` 的 uboot / kernel / rootfs / emu 各卷学习与验证，并尽量覆盖教程里的实验。
- **QEMU 机型**：上游只有 `mcimx6ul-evk`（6UL），没有独立 6ULL 机型；6ULL 与 6UL 地址映射/外设集基本一致，6ULL 的 dts 根 compatible 带 `fsl,imx6ul` fallback，因此「6UL 机型 + 6ULL dtb」可行。

## 2. 直启链路（kernel + rootfs）：可行

### 2.1 启动方式

完全不经过 U-Boot，由 QEMU 直接把内核、dtb 装进内存：

```bash
qemu-system-arm -M mcimx6ul-evk -m 512M \
  -kernel zImage -dtb imx6ull-aes.dtb \
  -append "console=ttymxc0,115200 root=/dev/mmcblk1 rootwait rw" \
  -drive file=rootfs.ext4,if=sd,index=1,format=raw -nographic
```

仓库把这条链封装成三件套（`scripts/qemu_helper/`）：

- `make-rootfs-img.sh`：rootfs 目录树 → 256 MB ext4（`mke2fs -d`，不需要 root）；
- `make-qemu-dtb.sh`：编译**真机同一份** `imx6ull-aes.dts`，再用 `fdtput` 注入两条 `local-mac-address`（等价 U-Boot 的 ethaddr fixup）；
- `run-qemu.sh`：启动 + 自动重建陈旧 dtb/rootfs + `--smoke` 断言。

### 2.2 硬约束

| 约束 | 说明 |
| --- | --- |
| SD 必须挂 USDHC2 | `-drive if=sd,index=1` → guest `/dev/mmcblk1`（index 0 是 USDHC1） |
| 整卡一个 ext4、无分区表 | 真机是 `mmcblk1p2`，因为真机 U-Boot 要从分区读内核；直启链里盘只当 rootfs |
| 镜像容量必须是 2 的幂 | QEMU SD 模型 CSD 限制，否则报 `SD card size has to be a power of 2`；脚本用 256 MB |
| `-m 512M` | 与板级 dts 的 `/memory` 一致；QEMU 会按 `-m` 改写 `/memory` |
| 必须自建 QEMU 11.1 | 发行版 8.2.2 对 mmdc/ocotp/qspi/pxp/dcp 等是**地址空洞**，真机 dtb 直接启动会 external abort 且串口全黑（死在 UART 驱动 probe 之前） |

### 2.3 证据链

- 教程 `document/tutorial/emu/` 8 章 + `assets/` 日志（qemu3–11.log、boot-clean.log、session-login.log、spi-quirk-debug.log）。
- CI `.github/workflows/ci-full.yml` 的 `qemu-smoke` job：装依赖 → `build-qemu.sh` → `run-qemu.sh --smoke --no-build ... --append=earlycon`，断言日志出现 `buildroot login:`。
- 2026-08 Phase 0 验收记录：apt 8.2.2 直启到 `buildroot login:`，交互登录成功，`uname -a` 为 7.1.0 armv7l，`poweroff -f` 干净关机。

### 2.4 为什么 8.2.2 不行、而 11.1 行

真机 dts 里有 mmdc、ocotp、qspi、pxp、dcp、rngb、csi、tsc、usbmisc 等节点。8.2.2 对这些地址既无模型也无桩，`readl` 触发 external abort，内核在 UART probe 前就死了，表现为「串口完全无输出」。自建 11.1 在上游补了一批桩（读 0、写丢弃，属软失败），再加上 `patches/qemu/` 的补丁，真机树才能整棵存活。

## 3. U-Boot 启动链：当前不可行

### 3.1 硬阻断 A：没有 boot ROM / HAB，IVT-DCD 无人解析

真机启动是：boot ROM 读 eMMC boot 分区的 IVT/DCD → 按 DCD 初始化 DDR/时钟 → 跳到 U-Boot。QEMU 的 `mcimx6ul-evk` 没有这段 ROM 模型，所以：

> No boot-ROM/SPL emulation exists for this machine, so U-Boot images with IVT headers (u-boot-dtb.imx) cannot be booted via -bios.
> —— `scripts/qemu_helper/run-qemu.sh:30-38`

`-bios u-boot-dtb.imx` 只会把带 IVT 头的镜像当普通固件放到某处，没人解析 IVT，更没人执行 DCD。

唯一替代是 QEMU 的 generic-loader，把**无头** `u-boot.bin` 直接装到链接地址并设 PC：

```bash
-device loader,file=u-boot.bin,addr=0x87800000,cpu-num=0
```

（`cpu-num` 存在时 loader 在复位阶段 `cpu_set_pc`，见 `hw/core/generic-loader.c:67-69`、`:116-130`。）

但这只是「把二进制塞进内存并从那里开始执行」，DCD 该做的 DDR/时钟初始化并不会发生——这直接引出下一个阻断。

### 3.2 硬阻断 B：没有 MMDC 模型，内存被算成 16 MiB

U-Boot 板级代码的第一件事是从 MMDC 寄存器反推内存大小：

```c
int dram_init(void) {                 // board/nxp/mx6ull_aes_emmc/mx6ull_aes_emmc.c:33
  gd->ram_size = imx_ddr_size();
```

`imx_ddr_size()`（`arch/arm/mach-imx/mmdc_size.c:39-66`）读 `MMDC_P0_BASE_ADDR`（`0x021B0000`）的 `MDCTL`/`MDMISC`，按行/列/bank/位宽拼容量。而 QEMU 11.1 里 MMDC 只是桩：

```c
create_unimplemented_device("a7mpcore-mmdc", ...)   // hw/arm/fsl-imx6ul.c:207-208
```

桩上读回 0，代入公式：

```
bits = 11 + 0 + 0 + 1            = 12   // 基础位
     + row(ctl=0)                = 0
     + col_lookup[0]             = 9
     + bank_lookup[0]            = 3
     + width(ctl=0) + cs1(ctl=0) = 0
     = 24
ram_size = 1 << 24 = 16 MiB
```

后果：U-Boot 按 16 MiB 内存重定位、加载内核、并把 `/memory` fixup 成 16 MB，必然失败。真机上这些寄存器是 boot ROM 执行 DCD（`imximage.cfg`）写好的，QEMU 没人干这活。**这正是 Bin Meng 系列要补「MMDC 几何」的原因。**

### 3.3 硬阻断 C：上游修复系列没有发布

Bin Meng 的 10 补丁系列（2026-08-12，SCU 兼容窗口 + MMDC 几何 + 3 个 uSDHC quirk）当时在 patchew 标记 applied，但**没有进 master**（调研笔记 `2026-08-25-qemu-board-emulation-research.md:63-67`）。项目 pin 的 v11.1.0 不含；截至 2026-11-13 的 v11.2.0-rc0 **仍然不含**（第 5 节核查）。

### 3.4 两个软阻断

| 阻断 | 现象 | 影响 |
| --- | --- | --- |
| eMMC 变 SD | QEMU 两个 USDHC 都挂 `TYPE_SD_CARD`；板级 dts 把 usdhc2 当 non-removable 8-bit eMMC | U-Boot 的 `CONFIG_SUPPORT_EMMC_BOOT`（defconfig 第 63 行）与 boot partition 操作没有对象；真机 `emmcboot` 叙事复现不了 |
| 板级初始化缺模型 | `setup_fec()` 写 IOMUXC GPR + ANATOP 时钟；IOMUXC 是 stub，ANATOP 部分未建模；PMIC（I2C）无模型 | U-Boot 网络、PHY reset 大概率起不来；不致命但「真机等价」缺环 |

### 3.5 强行跑 U-Boot 的代价

若一定要在 QEMU 里看到 U-Boot：

1. 给板级 U-Boot 加一行仿真 workaround（如 `gd->ram_size = 512 * SZ_1M;`，绕过 `imx_ddr_size()`），或 backport MMDC 模型；
2. SD 镜像改成真机分区布局（p1 ext4 放 zImage+dtb，p2 rootfs），U-Boot 里用 `mmc dev 1; ext4load ...; bootz`；
3. 还要和 uSDHC quirk、FEC 时钟、PMIC 初始化搏斗。

工作量天级，且 workaround 会破坏「单源」纪律，只能作为隔离的仿真实验分支。

## 4. 外设覆盖

| 档位 | 项目 | 在 QEMU 里的表现 |
| --- | --- | --- |
| 真模型 | UART、FEC、USDHC/SDHCI、GPIO、I2C/SPI 控制器、eLCDIF（11.1+）、RTC/WDOG/GPT、USB host | 正常 probe |
| 本仓库补丁补的 | FlexCAN2 接线、PWM、ap3216c、icm20608、gt911 触摸、wm8960、gpio_set、AIPS 空洞补桩（16 个 patch） | 教程演示的触摸/传感器/背光/显示靠这批 |
| 缺或桩 | ADC、SAI+SDMA（音频 DMA）、IOMUXC、PMIC、eMMC boot 分区 | probe `-110` / deferred，属已知软失败 |

即：**QEMU 里能演示的触摸、光照、六轴、LCD，是本仓库自己写模型补出来的**，换一份干净 QEMU 并没有。

## 5. v11.2.0-rc0 核查（2026-11-13）

### 5.1 方法

```bash
git ls-remote --tags https://github.com/qemu/qemu.git 'v11.2*'
# a8214179e9090626b1d25f087ea9357ec9c44e43  refs/tags/v11.2.0-rc0
# 29760efaf96bbe5928f8111881eddbf5ac06439e  refs/tags/v11.2.0-rc0^{}
```

- 用 raw.githubusercontent 直接取 `v11.2.0-rc0` 下的 `hw/arm/fsl-imx6ul.c`、`hw/arm/mcimx6ul-evk.c`、`hw/sd/sdhci.c`、`docs/system/arm/mcimx6ul-evk.rst`；
- 用 partial clone（`--filter=blob:none`）取 rc0 的 tree，与本地 v11.1.0 逐文件 diff；
- 用 GitHub atom feed 查目标文件的提交历史；
- 对怀疑新增的 `hw/misc/imx6ul_mmdc.c` 做 404 验证（rc0 与 master 都无此文件）。

### 5.2 结果

| 检查项 | v11.1.0 | v11.2.0-rc0 | 判定 |
| --- | --- | --- | --- |
| MMDC 模型 | 桩 | **仍是桩**，`fsl-imx6ul.c:207-208` 原样 | 未合并 |
| `hw/misc/imx6ul_mmdc.c` | 无 | 404（master 也 404） | 系列未落地 |
| `mcimx6ul-evk.c` | — | 仅新增 `mc->default_ram_size = 512 * MiB;` 与 QOM 改造（`sysbus_realize_and_unref`、`DEFINE_MACHINE`） | 无 boot ROM/启动链支持 |
| `hw/sd/sdhci.c` | — | 253 行 diff，全是通用 SDMA 改造（`sdhci_sdma_address` / `sdhci_advance_sdma_address` / `sdhci_resume_sdma_transfer` / hostctl2 vmstate） | 无 i.MX 专用 quirk |
| `docs/system/arm/mcimx6ul-evk.rst` | 210 B / 4 行 | 未变 | 无 U-Boot 文档 |
| `fsl-imx6ul.c` 提交历史 | — | 仅 2026-10-28 三项 QOM 重构（gpt/epit 时钟 link、继承 `TYPE_SYS_BUS_DEVICE`）+ 2026-04-27 LCDIF | 无 2026-09 的 MMDC/启动链提交 |

### 5.3 结论

**v11.2.0-rc0 未合并 Bin Meng 的 MMDC / U-Boot 启动链系列**；`git ls-remote` 目前也只有 rc0、没有 rc1。因此：

- 「等 11.2 正式版就能跑 U-Boot」**不成立**（除非后续 rc 合并，需持续复查）；
- U-Boot 链只剩两条路：**backport 那 10 个补丁**，或**放弃在 QEMU 运行 U-Boot**。

## 6. 本机环境现状（2026-11-13）

| 检查项 | 状态 |
| --- | --- |
| 构建产物 `out/` | 空，什么都没编 |
| 自建 QEMU `out/qemu/build/qemu-system-arm` | 不存在；系统只有 8.2.2 |
| QEMU 构建依赖 | **缺** ninja、pkg-config、glib-2.0 / pixman / libfdt / zlib 开发包、libslirp0 |
| 交叉工具链 | **缺** `arm-none-linux-gnueabihf-*`；系统只有 `arm-linux-gnueabihf-gcc`，prefix 不匹配 |
| 内核子模块 | v7.2.9，干净；脚本会自动拷板级 dts、用模板生成 defconfig |
| buildroot | 2026.02，干净；最小 rootfs 无 Qt6，CI 约 15 分钟（Qt6 另加 2–4 h） |
| 磁盘 / CPU | 943 GB 可用，32 核 |
| Docker | daemon 未启动；且镜像不含 glib/pixman 开发包，容器路线省不掉装依赖 |

### 6.1 安装与构建（预计 40–70 分钟首次）

```bash
# 0) QEMU 构建依赖
sudo apt-get install -y ninja-build pkg-config libglib2.0-dev \
     libpixman-1-dev libfdt-dev zlib1g-dev python3-venv \
     device-tree-compiler libslirp0

# 1) ARM GNU Toolchain 15.2.rel1（按 ENVIRONMENT_SETUP.md:146-200）

# 2) 自建 QEMU v11.1 + patches/qemu/0001-0016
scripts/build_helper/build-qemu.sh
out/qemu/build/qemu-system-arm --version

# 3) 内核（zImage + imx6ull-aes.dtb）
scripts/build_helper/build-linux.sh

# 4) rootfs 用户空间（最小配置约 15 分钟）
scripts/build_helper/build-buildroot.sh

# 5) 打盘 + 启动
scripts/qemu_helper/make-rootfs-img.sh
scripts/qemu_helper/make-qemu-dtb.sh
scripts/qemu_helper/run-qemu.sh --smoke
```

| 阶段 | 预计耗时 | 说明 |
| --- | --- | --- |
| apt 依赖 + 工具链 | 5–15 min | 工具链下载约 100 MB |
| 自建 QEMU | 10–20 min | 单 target `arm-softmmu` |
| 内核 | 3–8 min | 32 核 |
| buildroot（最小） | ~15 min + 下载 | 无 Qt6 |
| 打盘 + smoke | 1–2 min | — |

## 7. 建议路线

原计划的「A. 等 QEMU 11.2」已被第 5 节证伪，路线更新为：

| 路线 | 做法 | 评价 |
| --- | --- | --- |
| **B（推荐先做）** | 现在把直启链跑通：内核、rootfs、驱动、外设、CI 冒烟都能练 | 40–70 分钟，成功率 >95% |
| **A′（实验分支）** | backport Bin Meng 10 补丁到 11.1 + 一行板级 `ram_size` workaround + 分区 SD 镜像 | 天级工作量，风险高，但能验证「U-Boot 能启动」 |
| **C（兜底）** | 放弃在 QEMU 运行 U-Boot，U-Boot 章节留真机；QEMU 只验证产物一致性 | 适合无板卡且主攻内核/驱动/应用 |

建议先 B；若确实需要 U-Boot 章节的模拟练习，再单开 A′ 分支，不要把它混进主线。

## 8. 验收判据

- **里程碑 1**：`run-qemu.sh --smoke` 退出 0，日志含 `buildroot login:`。
- **里程碑 2**：登录 `root/root` 后 `uname -a` 为 `7.2.9 ... armv7l`；`ip link` 能看到 FEC 网卡（若 deferred，属已知软失败）。
- **里程碑 3**：`e2e-test.sh` 的 15 项外设断言通过（触摸/传感器/CAN 等）。
- **不要**把「串口出现 U-Boot 版本行」当成功判据——当前不可能。

## 附录 A：关键文件与行号

| 文件 | 内容 |
| --- | --- |
| `scripts/qemu_helper/run-qemu.sh:30-43` | 直启链说明、无 boot ROM、Bin Meng 系列未发布 |
| `document/tutorial/emu/03_rootfs_image.md:94` | 整卡 ext4、`root=/dev/mmcblk1`、分区表差异 |
| `document/tutorial/emu/04_whack_a_mole.md` | 九轮打地鼠、8.2.2 地址空洞 |
| `document/tutorial/emu/05_toolchain.md:118` | 「U-Boot 链等 Bin Meng 系列进 release」 |
| `document/notes/2026-08-25-qemu-board-emulation-research.md:63-67` | Bin Meng 10 补丁与 `-device loader` 方案 |
| `.github/workflows/ci-full.yml:294-360` | qemu-smoke job |
| `third_party/uboot-mainline/board/nxp/mx6ull_aes_emmc/mx6ull_aes_emmc.c:33-34` | `dram_init()` → `imx_ddr_size()` |
| `third_party/uboot-mainline/arch/arm/mach-imx/mmdc_size.c:39-66` | MMDC 反推内存容量（16 MiB 计算） |
| `third_party/qemu/hw/arm/fsl-imx6ul.c:205-208` | MMDC 仍是 `create_unimplemented_device` |
| `third_party/qemu/hw/core/generic-loader.c:67-69,116-130` | loader 设 PC 的实现 |
| `scripts/build_helper/build-qemu.sh:20-26,73-75` | QEMU 构建依赖 |
| `scripts/build_helper/build-linux.sh:432-446,492` | 板级 dts 安装与 defconfig 生成 |
| `rootfs/buildroot/configs/imx6ull_aes_defconfig:20-33` | 外部工具链 15.2 / `/opt/arm-gnu-toolchain` |

## 附录 B：v11.2.0-rc0 复现命令

```bash
# 1) 标签与提交
git ls-remote --tags https://github.com/qemu/qemu.git 'v11.2*'

# 2) rc0 下的 MMDC 状态（应看到 create_unimplemented_device）
curl -fsSL https://raw.githubusercontent.com/qemu/qemu/v11.2.0-rc0/hw/arm/fsl-imx6ul.c \
  | grep -n -A2 'a7mpcore-mmdc'

# 3) 是否有独立 MMDC 模型（应 404）
curl -fsSL -o /dev/null -w '%{http_code}\n' \
  https://raw.githubusercontent.com/qemu/qemu/v11.2.0-rc0/hw/misc/imx6ul_mmdc.c

# 4) 与 v11.1.0 做 tree diff
git clone --filter=blob:none --no-checkout --depth=1 \
  --branch v11.2.0-rc0 https://github.com/qemu/qemu.git /tmp/q112
cd /tmp/q112 && git diff --stat HEAD -- hw/arm/fsl-imx6ul.c hw/arm/mcimx6ul-evk.c hw/sd/sdhci.c
```

> 复核时间：2026-11-13。若上游后续 rc 合并了 MMDC/启动链系列，第 3、5 节的结论需要改写。
