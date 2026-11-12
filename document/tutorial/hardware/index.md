---
title: 硬件与启动原理
---

<PageHeader title="硬件与启动原理" description="在敲第一条编译命令之前,先把 i.MX6ULL 这颗芯片和它的启动链路看明白" />

## 为什么要有这一卷

很多教程从「装工具链、make、烧卡」开始,能跑通,但一旦卡住就无从下手:串口一片空白、DRAM 大小不对、SD 卡识别不到、屏幕不亮……这些问题的答案都不在构建脚本里,而在芯片手册和板级硬件里。

这一卷不教你敲命令,而是回答「为什么」:

- 上电后最先运行的代码在哪里?它怎么找到你的 U-Boot?
- `.imx` 文件里到底有什么?为什么必须写在卡的 1 KiB 偏移?
- DDR 是谁初始化的?U-Boot 怎么知道自己有 512 MiB 内存?
- 时钟从 24 MHz 晶振怎么变成 528 MHz、396 MHz、51.2 MHz?
- 一个引脚为什么能当 UART、又能当 GPIO?`0x49` 这种数字是什么意思?
- SD 卡插上去,控制器和卡之间发生了什么?
- 屏幕的 1024×600 时序参数是怎么算出来的?

每一章都尽量落到**本仓库真实存在的文件与真实抓到的数据**上:U-Boot 的 `.imx` 头、DCD 里的 60 条寄存器写、设备树里的 panel timing、QEMU 里为跑通启动链而写的模型。

## 章节

<ChapterNav>
  <ChapterLink num="01" href="01_soc_overview">芯片全景与内存地图</ChapterLink>
  <ChapterLink num="02" href="02_boot_rom">Boot ROM、IVT 与 .imx 镜像</ChapterLink>
  <ChapterLink num="03" href="03_ddr_mmdc">DDR 与 MMDC:内存是怎么被点亮的</ChapterLink>
  <ChapterLink num="04" href="04_clock_power">时钟与电源:从 24 MHz 到满速运行</ChapterLink>
  <ChapterLink num="05" href="05_pinmux">引脚复用与电气属性:IOMUXC 与 pad</ChapterLink>
  <ChapterLink num="06" href="06_storage">SD/eMMC 与 USDHC:启动介质</ChapterLink>
  <ChapterLink num="07" href="07_uart_display">串口与显示:bring-up 的两只眼睛</ChapterLink>
  <ChapterLink num="08" href="08_full_flow">把全流程串起来:从裸片到 login</ChapterLink>
</ChapterNav>

## 怎么读

| 你的情况 | 建议 |
| --- | --- |
| 完全没接触过 i.MX6ULL | 按 01 → 08 顺序读,每章都先讲原理再落到本仓库 |
| 只想弄懂启动失败怎么查 | 直接读 02、03、08,再回看 06 |
| 正在做 U-Boot 移植 | 02、04、05、06 必读,配合 [U-Boot 移植](../uboot/) |
| 正在做内核/设备树 | 04、05、07 必读,配合 [内核移植](../kernel/) |
| 没有板子,用 QEMU | 每章末尾的「QEMU 视角」会说明模型与真机的差异 |

::: tip 与其他卷的关系
本卷讲原理,[系统构建](../system-build/)讲操作,[模拟与调试](../emulation/)讲没有板子时怎么验证。三卷对照着看,遇到问题时能同时知道「硬件上发生了什么」和「该敲哪条命令」。
:::

## 预备知识

- 会基本的 Linux 命令行,知道编译、烧写大概在做什么
- 读过 [学习路线图](../start/00_roadmap) 或 [硬件接口速查](../start/03_hardware_quick_reference)
- 不需要会写汇编,但知道「寄存器就是内存地址上的一个 32 位数」会轻松很多

## 本卷用到的资料来源

原理部分主要依据 NXP 官方文档,实践部分全部来自本仓库代码与实测:

- 《i.MX 6ULL Applications Processor Reference Manual》(IMX6ULLRM),尤其 System Boot、CCM、IOMUXC、MMDC、uSDHC、eLCDIF 各章
- 《i.MX 6ULL Data Sheet》(IMX6ULLCEC),电气参数与频率档位
- U-Boot 源码:`arch/arm/mach-imx/`、`drivers/mmc/fsl_esdhc_imx.c`、`tools/imximage.c`
- Linux 源码:`drivers/pinctrl/freescale/`、`drivers/mmc/host/sdhci-esdhc-imx.c`
- 本仓库:板级补丁、设备树、QEMU 补丁与实测日志

> 手册页数以千计,本卷不会逐条抄寄存器,而是把「一条启动链上真正会用到的部分」挑出来,并告诉你需要细节时去手册的哪一章查。
