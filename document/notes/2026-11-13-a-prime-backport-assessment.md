---
title: "A′ 可行性评估：Bin Meng 10 补丁 backport 到 QEMU v11.1.0"
description: "结论：补丁可 10/10 干净应用，编译依赖可无 root 解决；真正的不确定性在 U-Boot 2026.10 与 QEMU 11.1+补丁的运行时兼容，预计 1 人日（顺利）到 2–3 人日（含调试）。"
date: 2026-11-13
---

# A′ 可行性评估：10 补丁 backport 到 v11.1.0

> 目标（来自 [可行性评估](2026-11-13-qemu-custom-system-feasibility.md) §7 路线 A′）：把上游
> "Enable U-Boot boot on MCIMX6UL-EVK" 系列移植到 pinned 的 v11.1.0，让**本仓库的定制 U-Boot**
> 在 `mcimx6ul-evk` 上出串口 banner、从 USDHC2 的 SD 卡加载 zImage 并 `bootz`。

## 结论

| 维度 | 结论 | 依据 |
| --- | --- | --- |
| 补丁可用性 | ✅ 10/10 干净应用，零冲突、零 fuzz | 在 v11.1.0 的临时 worktree 上顺序 `git apply` 全部成功 |
| 编译 | ✅ 大概率通过（依赖全部可无 root 获取，meson 1.12.1 已本地验证） | `apt-get download` + `get-pip` 均可用；改动 API 均是 11.1 已有符号 |
| 运行 | ⚠️ 中等风险，链路可通 | 最大变量是 U-Boot 2026.10（系列只测过 Buildroot 的 2024.07）与 QEMU 模型的新旧差异 |
| 工作量 | **顺利 4–6 小时；含调试 1–2 人日**（不含 rootfs 长下载时） | 见 §5 门禁表 |

**判断：A′ 值得做，且比原文档"天级"的估计更乐观**——补丁这一侧的移植成本几乎为零，成本集中在内核/镜像/串口联调。

## 1. 已完成的实证

### 1.1 补丁来源

- 系列：[PATCH 00/10] hw/arm: Enable U-Boot boot on MCIMX6UL-EVK，作者 Bin Meng，2026-08-12 09:36 +0800。
- 在线位置：`lists.nongnu.org` 的 qemu-devel 2026-08 存档 mbox（patchew/lore 在本环境 403 或空响应）。
- 已抽取正文到 `/tmp/qserie/series10/p01.patch … p10.patch`（临时目录，未入库），cover letter 在 `p00.patch`。
- 系列自带 `base-commit: e8d693e12af9cbb89d724baadfcc08559669e279`、`branch: imx6ul-evk`。

### 1.2 应用结果（v11.1.0 = 84f0721）

```bash
git -C third_party/qemu worktree add --detach /tmp/q11 v11.1.0
for i in 01 02 03 04 05 06 07 08 09 10; do
  git -C /tmp/q11 apply /tmp/qserie/series10/p$i.patch
done
```

10 个补丁全部 `APPLIED`。最终状态：9 个文件修改 + 1 个新增
（`tests/functional/arm/test_mcimx6ul_evk.py`），QEMU C 代码 245 insertions，加测试共 315+/22−，
与 cover letter 的 diffstat 完全一致。

### 1.3 补丁清单

| # | 标题 | 作用 | 针对本项目的问题 |
| --- | --- | --- | --- |
| 01 | fsl-imx6ul: Add SCU compatibility window | 在 `A7MPCORE+0x4` 放 4 字节占位 | U-Boot i.MX6 CPU 识别读 SCU，Cortex-A7 该地址保留 → data abort |
| 02 | imx6ul_ccm: Update PMU_MISC0 reset value | `0x04000000 → 0x04000080` | U-Boot `init_bandgap()` 等 `REFTOP_VBGUP`，旧值永远等不到 |
| 03 | fsl-imx6ul: Map early firmware register placeholders | 补 AIPS1/2 配置、SNVS LP、system counter 控制窗口 | U-Boot 在串口可用前访问这些块 → abort |
| 04 | fsl-imx6ul: Add a minimal MMDC geometry model | 用只读 MMDC 模型替换 16 MiB 桩，按 `-m` 推导 row | 本项目 §3.2 的 16 MiB 致命阻断 |
| 05 | sdhci: Use a QEMU-local no-busy IRQ quirk bit | `BIT(14) → BIT(0)`，让出 bit 14 给新 quirk | 内部 quirk 位与 Linux 无关 |
| 06 | sdhci: Honor i.MX uSDHC vendor clock gates | 认 `VEND_SPEC` 的 IPGEN/HCKEN/PEREN/CKEN | U-Boot 不写标准时钟位 → QEMU 丢命令 |
| 07 | sdhci: Preserve uSDHC status enables for U-Boot | RSTA 后保留 INT_STATUS_EN | U-Boot 二次 RSTA 后轮询不到完成状态 |
| 08 | sdhci: Skip SDMA boundary stops for i.MX uSDHC | `NO_SDMA_BOUNDARY` quirk | uSDHC 不做 512 KiB 边界停 |
| 09 | docs: Document Buildroot boot | 官方文档补 U-Boot/直启命令 | 给出 loader 方式与镜像约束（84 MiB → resize 128 MiB） |
| 10 | tests: Add MCIMX6UL-EVK boot tests | 功能测试，资产在 GitHub release | 可选；A′ 不需要 |

### 1.4 关键模型核验：512 MiB 能否正确推导

`-m 512M` → `pow2floor(512M)=2^29` → `size_bits=29` → `row=MIN(29-25,7)=4`
→ `MDCTL = BIT(31)|(4<<24)|BIT(20)|BIT(19) = 0x84180000`，`MDMISC=0x1740`。

U-Boot `arch/arm/mach-imx/mmdc_size.c:imx_ddr_size()` 解码：
`bits = 12 + row(4) + col_lookup[1](10) + bank_lookup[0](3) + width(0) + cs1(0) = 29` → **512 MiB**。
即本项目的 16 MiB 阻断会被这个模型精确修复，**不需要**再给 U-Boot 加 `ram_size` workaround。

## 2. 编译可行性

需要：`meson >= 1.5`、ninja、glib-2.0-dev、pixman-1-dev、libfdt-dev、zlib1g-dev、pkg-config。

本机现状与已验证的绕法（全部落在 `/tmp`，不动系统）：

| 依赖 | 现状 | 无 root 方案 |
| --- | --- | --- |
| meson | 系统无；Ubuntu noble 只有 1.3.2（QEMU 11.1 要 ≥1.5） | `get-pip.py` + 阿里云 pypi，已装 **meson 1.12.1** 到 `/tmp/pylibs` |
| ninja / pkg-config / glib-dev / pixman-dev / libfdt-dev / zlib-dev | 全缺 | `apt-get download`（aliyun 镜像，实测 3.2 MB）+ `dpkg-deb -x` 到本地前缀 |
| 工具链 | 缺 `arm-none-linux-gnueabihf-*` | ARM GNU Toolchain 15.2.rel1 解压到 `/tmp` |

预计编译时间：32 核约 10–20 分钟出 `qemu-system-arm`。

## 3. 运行链路还缺什么

| 组件 | 现状 | 需要的事 |
| --- | --- | --- |
| QEMU | v11.1.0 + 本系列（待编译） | G0：按 §2 构建 |
| U-Boot | 子模块已打 charlies 补丁；无 SPL；有 `CMD_MMC/EXT4/FAT/BOOTZ` | 用 `-device loader,file=u-boot-dtb.bin,addr=0x87800000,cpu-num=0`（**不能** `-bios .imx`，无 boot ROM 解析 IVT） |
| SD 镜像 | `build_imx6ull_image.sh` 已支持 | `--boot-media emmc` 恰好给出 `mmc 1` / `/dev/mmcblk1p2`，与 QEMU `if=sd,index=1`（USDHC2）编号一致；p1 ext4 自动放 zImage、dtb、boot.cmd |
| 内核 dtb | 两条路 | A：用 `imx6ul-14x14-evk.dtb`（QEMU 验证过，风险低）；B：用本板 `imx6ull-aes.dtb`（更真实，但要停用 QEMU 没有的外设） |
| 控制台 | `-nographic` | U-Boot `bootdelay=-1` 直接进命令行，手工敲 `ext4load`/`bootz` 即可 |

启动命令草案：

```bash
out/qemu/build/qemu-system-arm -M mcimx6ul-evk -m 512M \
  -device loader,file=out/release-latest/uboot/u-boot-dtb.bin,addr=0x87800000,cpu-num=0 \
  -drive file=out/release-latest/images/imx6ull-aes-emmc.img,if=sd,index=1,format=raw \
  -nographic
```

## 4. 风险登记

| ID | 风险 | 概率 | 缓解 |
| --- | --- | --- | --- |
| R1 | U-Boot 2026.10 的 `fsl_esdhc` 用 `clk_get_rate(per_clk)` 读 CCM/ANATOP；QEMU 给出 0 → probe 失败 | 中 | `mmc list` 看设备；必要时板级 dts 加 `assigned-clock-rates`，或在板级文件写死 `sdhc_clk` |
| R2 | 板级 dts 的 `usdhc2` 是 non-removable 4-bit eMMC，QEMU 挂的是 SD 卡 | 中 | 优先探测；失败则 QEMU 侧改 4-bit/去 non-removable，或改用 `usdhc1`（QEMU `index=0`） |
| R3 | 板级 dts 无 `aliases`，mmc 编号不确定 | 低 | `mmc list` 确认后再 `mmc dev N` |
| R4 | 新 U-Boot 访问未建模寄存器（WDOG/GPC/SRC）导致 hang | 中 | `-d guest_errors` 定位具体地址，再补 `create_unimplemented_device` |
| R5 | meson/pip 需要联网 | 低（已验证） | pypi 与 aliyun 镜像均 200；离线时用 apt deb + 本地 wheel |
| R6 | 内核用本板 dtb 与 QEMU 模型不符 | 中 | 先跑通 EVK dtb，再替换 |

## 5. 分阶段计划与门禁

| 阶段 | 内容 | 通过标准 | 估计 |
| --- | --- | --- | --- |
| G0 | 装依赖、编 QEMU（11.1 + 10 补丁） | `qemu-system-arm --version` = 11.1.0 | 30–60 min |
| G1 | loader 载 U-Boot，开串口 | 看到 U-Boot banner / `=>` 提示符 | 30 min |
| G2 | 内存校验 | `bdinfo` 的 DRAM 或 `md` 显示 512 MiB | 15 min |
| G3 | SD 卡探测 | `mmc list` 有设备、`mmc dev 1; mmc info` 能读 CSD | 30–90 min |
| G4 | 读内核 | `ext4load mmc 1:1 ${loadaddr} /zImage` 成功 | 30 min |
| G5 | 启动 Linux | `bootz` 后到 `buildroot login:` | 1–4 h |

顺利路径 ≈ 4–6 h；若 R1/R2/R4 命中，加 0.5–1.5 天调试。

## 6. 与既有结论的关系

- [2026-08-25 调研笔记](2026-08-25-qemu-board-emulation-research.md) 说该系列 "patchew applied 但未进 master"：本次实证与之一致，且 v11.2.0-rc0 仍无（见 [可行性评估](2026-11-13-qemu-custom-system-feasibility.md) §5）。
- 2026-08-19 之后出现的 16 补丁系列（`SDCLK_AUTO_GATE` / `NO_SDMA_BOUNDARY`，作者 Kyle Fox，面向 i.MX95）**不是**本系列的 v2，是独立工作；两边都改 `sdhci.c`，将来合并时可能冲突，但不影响本次 backport。
- 原文档把 A′ 估成 "天级" 偏保守：真正的移植成本几乎为零，主要成本在 U-Boot 2026.10 的运行时兼容与镜像组装。

## 附：复现命令

```bash
# 1) 补丁（临时目录，未入库）
ls /tmp/qserie/series10/p*.patch

# 2) 干净应用检查
git -C third_party/qemu worktree add --detach /tmp/q11 v11.1.0
for i in 01 02 03 04 05 06 07 08 09 10; do
  git -C /tmp/q11 apply /tmp/qserie/series10/p$i.patch || echo "p$i FAILED"
done
git -C /tmp/q11 status --short ; git -C /tmp/q11 diff --stat | tail -1
```
