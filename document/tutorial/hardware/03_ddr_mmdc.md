---
title: DDR 与 MMDC:内存是怎么被点亮的
---

# DDR 与 MMDC:内存是怎么被点亮的

U-Boot 启动时打印的 `DRAM: 512 MiB`,背后是两件事:DDR 已经被初始化好(真机由 DCD 完成),以及 U-Boot 从 MMDC 控制器里正确读出了"有多大"。前一件事错了板子根本不启动,后一件事错了内核会在解压阶段莫名其妙地崩。

这一章拆开看:i.MX6ULL 的 DDR 控制器 MMDC 长什么样、DCD 里那 34 条写干了什么、U-Boot 用什么公式算容量,以及 QEMU 为了复现这条链路补了一个什么样的模型。

## 3.1 DDR 的基本单位

DDR 内存不是"一块连续的黑盒",而是由 bank、row、column 组成的二维阵列:

- **bank**:芯片内部可以并行操作的存储体,本项目是 8 bank。
- **row(行)**:激活命令打开一行,16 KiB 左右,一次只能开一个 bank 的一行。
- **column(列)**:在已激活的行里选具体位置,按 burst 读写。
- **位宽**:i.MX6ULL 只支持 16 位 DDR3/DDR3L 或 LPDDR2。

一颗 16 位、15 行、10 列、8 bank 的 DDR3 容量是:

```text
2^15(row) × 2^10(col) × 2 B(16-bit) × 2^3(bank) = 2^29 B = 512 MiB
```

这个 29 位,正是后面 U-Boot 要"算"出来的数字。

## 3.2 DDR 上电后为什么不能直接用

DDR 的模拟特性决定了它必须经过一套初始化:

1. **上电与稳定**:VREF、DLL 锁定。
2. **模式寄存器配置**:burst 长度、CAS latency、写恢复时间。
3. **ZQ 校准**:校准输出驱动阻抗。
4. **写 leveling / 读校准**:补偿 PCB 走线延迟,找到采样窗口。
5. **PHY 训练**:调整延时线,直到读写稳定。

这些步骤由 MMDC 控制器和 DDR PHY 完成,需要写几十个寄存器。i.MX6ULL 把这些写序列放进 DCD,由 Boot ROM 在加载 U-Boot 之前执行——这就是为什么你在 U-Boot 里看不到"DDR 初始化"的代码。

## 3.3 MMDC 寄存器速览

MMDC 的配置寄存器在 `0x021B_0000`,每个通道 4 KiB:

| 偏移 | 寄存器 | 作用 |
| --- | --- | --- |
| `0x00` | MDCTL | 行/列/位宽/CS 数量,决定容量 |
| `0x04` | MDPDC | 电源管理、预充电策略 |
| `0x08` | MDOTC | 时序参数(ODT) |
| `0x0C` | MDCFG0 | 时序:tRCD、tRP、tRAS 等 |
| `0x10` | MDCFG1 | 时序:tRFC、tWR、tRTP 等 |
| `0x14` | MDCFG2 | 时序:刷新间隔 |
| `0x18` | MDMISC | bank 数、bank 交织、RALAT |
| `0x1C` | MDSCR | 控制器配置、ZQ 校准触发 |

DCD 里对 MMDC 的 34 次写,大体分三组:时序参数(MDCFG/MDOTC)、几何与电源(MDCTL/MDMISC/MDPDC)、以及通过 MDSCR 触发的校准流程。

## 3.4 U-Boot 怎么算出 512 MiB

`arch/arm/mach-imx/mmdc_size.c` 里的 `imx_ddr_size()` 只有二十来行,却把"读寄存器"和"算容量"讲得很清楚:

```c
static const unsigned char col_lookup[]  = {9, 10, 11, 8, 12, 9, 9, 9};
static const unsigned char bank_lookup[] = {3, 2};

int bits = 11 + 0 + 0 + 1;                 /* row + col + bank + width */

bits += ESD_MMDC_CTL_GET_ROW(ctl);         /* (ctl >> 24) & 7  */
bits += col_lookup[ESD_MMDC_CTL_GET_COLUMN(ctl)];
bits += bank_lookup[ESD_MMDC_MISC_GET_BANK(misc)];
bits += ESD_MMDC_CTL_GET_WIDTH(ctl);
bits += ESD_MMDC_CTL_GET_CS1(ctl);
```

对 `-m 512M` 的场景,MMDC 的寄存器值应该是:

```text
MDCTL  = 0x8418_0000
MDMISC = 0x0000_1740
```

逐位代入:

| 字段 | 取值 | 贡献位数 |
| --- | --- | --- |
| 基础值(11 + 16 位宽 1) | — | 12 |
| row `(ctl>>24)&7` | 4 | 4 |
| col `(ctl>>20)&7` = 1 → `col_lookup[1]` | 10 | 10 |
| bank `(misc>>5)&1` = 0 → `bank_lookup[0]` | 3 | 3 |
| width `(ctl>>16)&3` | 0(i.MX6ULL 固定 16 位) | 0 |
| CS1 `(ctl>>30)&1` | 0(单 rank) | 0 |
| **合计** | | **29 → 512 MiB** |

如果 MDCTL/MDMISC 读回全 0(比如控制器没实现),`row=0`、`col=0`、`bank=3`,结果会变成 24 位 = **16 MiB**。内存被"缩水"到 16 MiB,内核解压到 `0x8200_0000` 就写到内存之外,直接死机。这是 i.MX6 上非常经典的一类"能进 U-Boot、一引导内核就挂"故障。

## 3.5 QEMU 为什么要补 MMDC 模型

QEMU 的 `mcimx6ul-evk` 早期把 MMDC 配置区做成 `create_unimplemented_device()`:读永远返回 0。这正好触发上面的 16 MiB 分支。

补丁 `0020-hw-arm-fsl-imx6ul-Add-a-minimal-MMDC-geometry-mod.patch` 做的事情很少,思路很值:

1. 给 SoC 状态加一个 `ram-size` 属性,由 machine 把 `-m` 的值传进来。
2. 注册一个 4 KiB 的只读 MemoryRegion,只实现两个偏移:

```c
case MMDC_MDCTL:  return fsl_imx6ul_mmdc_mdctl(s->ram_size);
case MMDC_MDMISC: return 0x1740;   /* 8 bank + interleave + RALAT5 */
```

3. 按容量反推行数:

```c
ram_size = pow2floor(MAX(ram_size, 16 * MiB));
size_bits = 63 - clz64(ram_size);
if (size_bits == 24)
    return BIT(31) | BIT(19);                 /* 16 MiB 特例 */
row = MIN(size_bits - 25, 7);
return BIT(31) | (row << 24) | BIT(20) | BIT(19);
```

`-m 512M` 时 `size_bits = 29`,`row = 4`,得到 `0x8418_0000`,和真实硬件配置一模一样;U-Boot 用同一套公式反推回 29 位,打印 512 MiB。

::: tip 模型不是"造假"
这个模型并不模拟 DDR 的电气行为,它只保证**固件读到的寄存器值与它将要访问的内存大小一致**。对启动链验证来说,这已经足够;对 DDR 驱动开发来说,当然不够。
:::

## 3.6 DDR 大小配错时会发生什么

| 现象 | 可能原因 |
| --- | --- |
| U-Boot 打印 `DRAM: 16 MiB` | MMDC 未实现/读回 0,或 DCD 未执行 |
| U-Boot 正常,`bootz` 后立即挂 | 内核/设备树被加载到实际内存之外 |
| 内核 earlycon 打印到一半停住 | 页表覆盖了未初始化区域 |
| 随机数据错误 | DDR 时序或 write leveling 参数不对 |

真机上还有一种情况:DCD 里的 DDR 参数是按"某颗料号"调的,换一颗 DDR 颗粒(容量、时序不同)就可能点不亮。这时要么改 DCD,要么改用 SPL 在运行时做 DDR 初始化(本项目没有 SPL,单级 U-Boot 依赖 DCD)。

## 3.7 从 DCD 到 U-Boot 的交接

把第 02 章和本章连起来看:

1. ROM 执行 DCD 里的 34 条 MMDC 写 → DDR 可以读写了。
2. ROM 把 U-Boot 从卡上搬到 `0x877F_F400` 起的地址(也就是 DDR)。
3. U-Boot 的 `board_init_f` 调用 `dram_init()`,后者调用 `imx_ddr_size()` 读 MDCTL/MDMISC。
4. U-Boot 把算出的 512 MiB 记进 `gd->ram_size`,后续 `bootz`、`ext4load` 都用它做边界检查。

所以在 QEMU 里,`-m 512M`、MMDC 模型、U-Boot 的 `dram_init()` 三者必须一致,少一个就会在启动日志里露出马脚。

## 3.8 想自己验证

真机上可以用 U-Boot 的 `md` 命令直接读 MMDC:

```text
=> md.l 0x021b0000 8
021b0000: 84180000 00000000 ...
021b0018: 00001740 ...
```

QEMU 里同样可以执行,读到的就是模型算出来的值。如果 `0x021b0000` 是 0,说明补丁没打上或机器没用对。

下一章离开内存,去看给这一切提供节拍的时钟系统——24 MHz 晶振怎么变成 528 MHz、396 MHz 和屏幕上那 51.2 MHz。

::: details 延伸阅读
- IMX6ULLRM 的 MMDC 章节(寄存器定义与时序参数)
- U-Boot 容量计算:`third_party/uboot-mainline/arch/arm/mach-imx/mmdc_size.c`
- QEMU 模型:`patches/qemu/0020-hw-arm-fsl-imx6ul-Add-a-minimal-MMDC-geometry-mod.patch`
- 本仓库实测记录:[QEMU 启动链笔记](../../notes/2026-11-13-qemu-bringup-progress)
:::
