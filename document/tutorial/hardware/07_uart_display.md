---
title: 串口与显示:bring-up 的两只眼睛
---

# 串口与显示:bring-up 的两只眼睛

板子第一次上电,你能依赖的信息只有两个:串口输出的字符,和屏幕上的画面。串口告诉你"系统跑到哪了",屏幕告诉你"图形通路对不对"。这一章把这两个子系统拆开:UART 的帧格式、波特率怎么算、earlycon 为什么重要;eLCDIF 的 RGB 时序、1024×600 的参数怎么来的,以及 QEMU 里它们各自被模拟到什么程度。

## 7.1 UART:最古老的调试接口

### 帧格式

异步串口没有时钟线,收发双方靠约定的波特率采样。一帧 8N1 长这样:

```text
空闲(高) ─┐ ┌─ D0 ─ D1 ─ D2 ─ D3 ─ D4 ─ D5 ─ D6 ─ D7 ─┐ ┌─ 空闲
          └─┘ 起始位(低)                          停止位(高)
```

- **起始位**:拉低一个比特时间,告诉对方"开始了"。
- **数据位**:低位先发,8 位。
- **校验位**:8N1 没有。
- **停止位**:拉高,至少 1 位。

接收方在起始位下降沿同步,然后在每个比特的中间采样。双方波特率偏差超过约 2–3%,采样就会落到错误的位。

### 波特率怎么来的

i.MX 的 UART 有一个参考时钟(通常来自 PERCLK 66 MHz 或 PLL3 80 MHz),内部再分频:

```text
bps = UART_CLK / (16 × (UBMR / UBIR))
```

`UBIR`/`UBMR` 两个寄存器组成一个比例,配合 16 倍过采样。U-Boot 的 `serial_mxc.c` 会根据 `CONFIG_SYS_NS16550_CLK`/实际时钟算出这两个值。

以 66 MHz、115200 为例:

```text
66,000,000 / (16 × 115200) ≈ 35.8
```

不是整数,所以必须用比例逼近。如果时钟源选错(比如实际是 80 MHz 却按 66 MHz 算),偏差会大到无法通信——表现为"能收到乱码,但认不出字符"。

### 寄存器与工作方式

| 寄存器 | 用途 |
| --- | --- |
| `URXD` | 接收数据 |
| `UTXD` | 发送数据 |
| `UCR1~4` | 使能、中断、DMA、协议配置 |
| `UFCR` | FIFO 控制、RX/TX 触发级别 |
| `USR1/2` | 状态(发送空、接收就绪、错误) |

数据量小时用中断 + FIFO;大量日志时用 DMA,避免每字节一次中断。

### earlycon:内核的第一声

内核启动早期,驱动框架还没初始化,普通 `console` 用不了。`earlycon` 是一段"绕过驱动模型"的极简输出代码,直接从设备树 `stdout-path` 拿到 UART 地址,轮询发送。

没有 earlycon,内核在 `console_init()` 之前的所有输出都会丢失——包括解压失败、页表错误、early panic。所以 bring-up 时的 bootargs 通常长这样:

```text
console=ttymxc0,115200 earlycon
```

本项目 CI 的 QEMU 冒烟测试就显式加了 `--append=earlycon`,否则内核早期崩溃时串口一片空白,根本没法定位。

## 7.2 eLCDIF:把帧缓冲变成 RGB 波形

### 接口信号

eLCDIF 输出的是并行 RGB 信号:

| 信号 | 作用 |
| --- | --- |
| `PCLK` | 像素时钟,每个周期送一个像素 |
| `DE` | 数据使能,有效期间才是可见像素 |
| `HSYNC` | 行同步,标志一行的开始 |
| `VSYNC` | 场同步,标志一帧的开始 |
| `DATA[23:0]` | RGB888,本板用 24 位 |

### 时序参数

一帧不是只有 1024×600 个可见像素,屏幕还要求前后沿(porch)和同步脉冲:

```text
一行 = HSYNC + HBP + 1024 + HFP
一帧 = VSYNC + VBP + 600  + VFP
```

本板设备树里的参数:

| 参数 | 值 | 含义 |
| --- | --- | --- |
| `clock-frequency` | 51,200,000 | 像素时钟 51.2 MHz |
| `hactive` / `vactive` | 1024 / 600 | 可见区域 |
| `hfront-porch` | 160 | 行前沿 |
| `hback-porch` | 140 | 行后沿 |
| `hsync-len` | 20 | 行同步宽度 |
| `vfront-porch` | 12 | 场前沿 |
| `vback-porch` | 20 | 场后沿 |
| `vsync-len` | 3 | 场同步宽度 |

验证一下像素时钟:

```text
(1024 + 160 + 140 + 20) × (600 + 12 + 20 + 3) × 60
= 1344 × 635 × 60
= 51,206,400 Hz ≈ 51.2 MHz
```

和 `clock-frequency` 完全对上。如果实际时钟偏低,画面会"抖"或黑屏;偏高则可能超出屏幕支持范围。

### 极性:最容易配错的地方

| 属性 | 本板值 | 含义 |
| --- | --- | --- |
| `hsync-active` | 0 | 行同步低有效 |
| `vsync-active` | 0 | 场同步低有效 |
| `de-active` | 1 | DE 高有效 |
| `pixelclk-active` | 0 | 像素时钟边沿选择 |

极性配反的典型现象:画面整体左右/上下偏移、出现黑边、或者完全花屏但背光亮。这类问题改时序参数没用,要改极性。

### 帧缓冲与控制器

驱动把一块内存(帧缓冲)交给 eLCDIF,控制器按 DMA 方式逐行读出,加上时序信号送到屏幕。关键寄存器:

| 寄存器 | 作用 |
| --- | --- |
| `CTRL` | 使能、数据宽度、DOTCLK 模式、主/从模式 |
| `CTRL1` | 字节打包格式 |
| `TRANSFER_COUNT` | 本帧的行数/列数 |
| `CUR_BUF` | 当前帧缓冲地址 |
| `VDCTRL0~4` | 时序、极性、同步宽度、等待周期 |

本板 U-Boot 的 `setup_lcd()` 很简单:开 LCDIF 时钟、把背光 GPIO 拉高。真正的时序初始化在 Linux 的 `mxsfb` 驱动里,由设备树 `panel-timing` 驱动。

### 背光

背光走 PWM1:

```dts
backlight_display: backlight-display {
    compatible = "pwm-backlight";
    pwms = <&pwm1 0 5000000 0>;   /* 周期 5 ms = 200 Hz */
};
```

200 Hz 高于人眼闪烁融合频率,又不会让背光升压电路效率太低。

## 7.3 bring-up 时怎么用这两只眼睛

| 阶段 | 串口应该看到 | 屏幕应该看到 |
| --- | --- | --- |
| 上电 | 无(ROM 静默) | 黑 |
| U-Boot | banner、DRAM、MMC、`=>` | 可能显示 logo(若开启) |
| 内核 earlycon | `Booting Linux...`、内存信息 | 无 |
| 内核 console | 驱动 probe 日志 | 背光亮,可能花屏 |
| 用户态 | `buildroot login:` | 控制台/应用画面 |

串口停在某一行,就说明卡在那一步之后;屏幕亮但花屏,通常是时序/极性/帧缓冲格式问题,而不是"没启动"。

## 7.4 QEMU 视角

- **UART**:QEMU 的 `imx.serial` 是完整模型,支持 FIFO、中断、DMA 请求。串口输出就是 QEMU 进程的 stdio(`-nographic` 时)。
- **eLCDIF**:QEMU 11.1 起有真实模型,能按 `panel-timing` 产生帧,`--display gtk` 或 VNC 可以看到画面。本项目启动链不依赖显示,所以 QEMU 冒烟测试只验证串口到 login。
- **背光/PWM**:QEMU 的 PWM 模型只保证寄存器可读写,不驱动真实背光。

这也解释了为什么"没有板子也能学":串口和存储是启动链的硬需求,QEMU 都给了;显示是锦上添花,QEMU 给了模型但不影响启动。

下一章把前面所有内容串成一条完整链路:从空目录到 `buildroot login:`,每一步的产物、命令和验收标准。

::: details 延伸阅读
- IMX6ULLRM 的 UART 与 eLCDIF 章节
- 本板 panel timing:`driver/device_tree/alpha-board/linux/imx6ull-aes.dtsi`
- Linux 显示驱动:`third_party/linux_mainline/drivers/video/fbdev/mxsfb.c`(或 DRM 版 `mxsfb`)
- U-Boot 显示驱动:`third_party/uboot-mainline/drivers/video/mxsfb.c`
:::
