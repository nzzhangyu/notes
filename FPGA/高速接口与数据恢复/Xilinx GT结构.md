# Xilinx GT 收发器结构

> 本文以 UltraScale/UltraScale+ GTH 为结构主线，结合 UG476、UG576、UG578 和 UG581 说明 Xilinx/AMD GT 的组成。GT 的核心不是单一 SerDes，而是由共享时钟资源、独立 TX/RX PMA、协议辅助型 PCS，以及复位、DRP 和调试逻辑共同构成。

## 文档范围

| 文档 | 适用范围 | 本文用途 |
| --- | --- | --- |
| UG476 v1.12.1 | 7 Series GTX/GTH | 说明 `CHANNEL + COMMON` 和 `CPLL + QPLL` |
| UG576 v1.7.1 | UltraScale/UltraScale+ GTH | 本文主要结构图来源 |
| UG578 v1.4 | UltraScale/UltraScale+ GTY | 对比更高速 GTY，结构与 GTH 大体同源 |
| UG581 v1.3 | Virtex UltraScale+ GTM | 说明 PAM4、LCPLL 和 `GTM_DUAL` 的结构变化 |

具体最高速率、PLL 工作范围和可用功能还取决于器件、封装与速度等级，应以器件 Data Sheet 为准。

## 先建立三个层次

理解 GT 时应区分三个层次：

1. **Quad/Dual**：物理资源组，包含参考时钟输入和共享 PLL。
2. **Channel**：一条独立 Lane，通常包含一套 TX、一套 RX 和 Channel PLL。
3. **TX/RX datapath**：每个方向又分为 PMA 与 PCS。

### PMA 与 PCS 的分工

| 区域 | 处理对象 | 典型模块 |
| --- | --- | --- |
| TX PMA | 高速串行时钟与模拟发送 | Clock Divider、Phase Interpolator、PISO、TX Driver、Pre/Post-emphasis |
| TX PCS | FPGA 并行数据与协议辅助处理 | TX Interface、8B/10B Encoder、Gearbox、Phase Adjust FIFO、Polarity |
| RX PMA | 模拟输入、采样和串并转换 | RX AFE、LPM/DFE、CDR、SIPO、OOB |
| RX PCS | 并行数据恢复和边界处理 | Comma Align、Decoder、Elastic Buffer、Gearbox、RX Interface |
| COMMON/Shared | 多 Channel 共享资源 | Reference Clock MUX、QPLL、共享配置与监测 |

一句话概括：

> PMA 负责“把电信号可靠地变成 bit，或把 bit 可靠地发到线上”；PCS 负责“这些 bit 如何组成用户能够使用的并行字和协议符号”。

## GT 的物理组织

### 7 Series GTX/GTH

UG476 中，一组典型 GTX/GTH Quad 包含：

- 四个 `GTXE2_CHANNEL` 或 `GTHE2_CHANNEL`；
- 每个 Channel 内一个 `CPLL`；
- 一个 `GTXE2_COMMON` 或 `GTHE2_COMMON`；
- Common 内一个可供 Quad 中多个 Channel 使用的 `QPLL`。

`CPLL` 只能服务所在 Channel；`QPLL` 是 Quad 共享资源。TX 和 RX 分别选择串行时钟源，因此同一 Channel 的 TX、RX 不一定使用同一个 PLL。

### UltraScale/UltraScale+ GTH/GTY

UG576/UG578 中的典型 Quad 包含：

- 四个 `GTHE3/4_CHANNEL` 或 `GTYE3/4_CHANNEL`；
- 每个 Channel 一个 `CPLL`；
- 一个 `GTHE3/4_COMMON` 或 `GTYE3/4_COMMON`；
- Common 内两个共享 PLL：`QPLL0` 和 `QPLL1`。

QPLL0、QPLL1 可以向 Quad 内四个 Channel 分发时钟。每个 Channel 的 TX、RX 均可按合法配置选择 CPLL、QPLL0 或 QPLL1。

这并不表示三个 PLL 在任何 Line Rate 下都能互换。PLL 的 VCO 范围、输出分频和参考时钟组合必须合法。

### 关于 7 Series GTP

GTP 主要用于 Artix-7 等成本和功耗敏感的较低速接口，本文不展开其内部结构。需要注意：其 Dual/PLL 组织不同于 UG476 中的 GTX/GTH，不能直接套用后文的 `CPLL + QPLL` 模型；涉及 GTP 项目时应单独参考 [UG482](https://docs.amd.com/v/u/en-US/ug482_7Series_GTP_Transceivers)。

### GTM

GTM 的变化更大。UG581 中的 GTM 以 `GTM_DUAL` 为主要 Primitive，一组包含两个 Channel，并共享 LCPLL；它支持 NRZ/PAM4，也没有传统意义上的独立 Channel Primitive。因此，GTM 应单独按 UG581 或 Versal AM017 理解。

## Channel 时钟结构

![UG576 Figure 2-11：Internal Channel Clocking Architecture](assets/Xilinx-GT结构/ug576-fig2-11-channel-clocking.png)

> 图 1：UltraScale GTH Channel 内部时钟结构。裁自 UG576 v1.7.1 Figure 2-11。

从图中可以读出三个关键关系：

1. 参考时钟经过 `REFCLK Distribution` 送入 Channel。
2. Channel 内的 `CPLL`，或 Common 送来的 `QPLL0/1`，可以成为 TX/RX 串行时钟源。
3. TX、RX 具有独立的 Clock Divider，分别产生 PMA 与 PCS 所需时钟。

因此，GT 时钟链应按以下顺序分析：

```text
外部 MGTREFCLK
    → 专用参考时钟缓冲与分配网络
    → CPLL 或 QPLL0/QPLL1
    → TX/RX Clock Divider
    → 串行时钟、内部并行时钟
    → TXOUTCLK/RXOUTCLK
    → BUFG_GT/User Clock Helper
    → TXUSRCLK(2)/RXUSRCLK(2)
```

`TXOUTCLK`、`RXOUTCLK` 通常还要经过 `BUFG_GT` 和 Wizard 生成的 User Clock Helper，才能驱动 FPGA Fabric 并反馈至 `TXUSRCLK*`、`RXUSRCLK*`。不能把 `OUTCLK`、`USRCLK` 和外部参考时钟看作同一个时钟。

### CPLL 内部结构

![UG576 Figure 2-12：CPLL Block Diagram](assets/Xilinx-GT结构/ug576-fig2-12-cpll.png)

> 图 2：UltraScale GTH CPLL 结构。裁自 UG576 v1.7.1 Figure 2-12。

CPLL 是典型的反馈 PLL：

- 输入参考时钟首先经过 `/M`；
- PFD 比较输入与反馈时钟；
- Charge Pump 和 Loop Filter 控制 VCO；
- `/N1`、`/N2` 构成反馈分频；
- Lock Indicator 产生 `CPLLLOCK`。

概念上的输出频率关系为：

\[
f_{\text{PLLCLKOUT}}
=
f_{\text{PLLCLKIN}}
\times
\frac{N1 \times N2}{M}
\]

后续还要经过 TX/RX Output Divider 才得到目标 Line Rate。因此，`PLLLOCK=1` 只表示 PLL 频率进入规定容差，并不表示 TX/RX 数据通路或上层链路已经可用。

## TX 发送通路

![UG576 Figure 3-1：GTH Transceiver TX Block Diagram](assets/Xilinx-GT结构/ug576-fig3-1-tx-block.png)

> 图 3：UltraScale GTH TX 完整结构。裁自 UG576 v1.7.1 Figure 3-1。图中数据总体从右向左流动。

沿图从右向左阅读：

### 1. TX Interface

`TX Interface` 是 FPGA Fabric 与 GT PCS 的边界，接收 `TXDATA`、`TXCTRL*` 等并行信号。

用户接口宽度与 GT 内部数据宽度可能不同，因此 `TXUSRCLK` 和 `TXUSRCLK2` 也可能同频或呈 2:1 关系。实际关系由 `TX_DATA_WIDTH`、`TX_INT_DATAWIDTH` 及所选编码路径决定。

### 2. 编码与协议辅助路径

图中提供多条可选路径：

- 8B/10B Encoder；
- 128B/130B Encoder；
- TX Sync Gearbox；
- TX Async Gearbox；
- PCIe PIPE Control；
- Pattern Generator。

多路选择器根据配置选择其中一条数据路径。它们是 PCS 内的协议辅助功能，不等于完整 PCIe、Ethernet 或 Aurora 协议栈。

### 3. Phase Adjust FIFO

Phase Adjust FIFO 即通常所说的 TX Buffer，用于吸收用户并行时钟和内部 XCLK 之间的相位差。

- 启用 Buffer：时钟连接和初始化较容易，但增加延迟。
- Bypass Buffer：可以降低或固定延迟，但必须执行 TX Phase Alignment。

### 4. Polarity 与 PISO

`Polarity` 可以在逻辑上翻转串行极性，用于补偿 PCB 上 P/N 交换。

随后 PISO 把 PCS 并行数据转换为高速串行数据。PISO 属于 TX PMA。

### 5. TX Driver

TX Driver 把串行数据驱动到 `TXP/TXN`，典型可调参数包括：

- Differential Swing；
- Main Cursor；
- Pre-cursor；
- Post-cursor；
- Electrical Idle；
- OOB/PCIe 相关发送控制。

图中从 `TX Pre/Post Emp` 返回 RX EQ 的连线用于 Near-End PMA Loopback，不是正常外部接收路径。

## RX 接收通路

![UG576 Figure 4-1：GTH Transceiver RX Block Diagram](assets/Xilinx-GT结构/ug576-fig4-1-rx-block.png)

> 图 4：UltraScale GTH RX 完整结构。裁自 UG576 v1.7.1 Figure 4-1。数据总体从左向右流动。

### 1. RX Analog Front End 与 Equalizer

`RXP/RXN` 首先进入 RX Analog Front End。图中将主要模拟处理概括为：

- RX EQ；
- DFE；
- RX OOB。

实际结构还包含终端、增益和采样相关电路。均衡器用于补偿通道损耗和码间串扰：

- LPM/线性均衡适合相对低损耗通道；
- DFE 使用历史判决结果补偿后游标 ISI，适合更高损耗通道。

具体选择必须结合 Line Rate、Insertion Loss、协议和器件代际。

### 2. CDR 与 SIPO

图中没有把 CDR 单独画成一个方框，其功能与 RX PMA 的采样、时钟和 SIPO 路径紧密结合。

CDR 负责恢复 bit 采样时钟；SIPO 将高速串行 bit 转换成内部并行数据。此时只是恢复了 bit 流，还没有保证字节或协议块边界正确。

### 3. Polarity、PRBS 与 Comma Align

- `Polarity` 补偿接收差分对 P/N 交换；
- `PRBS Checker` 用于不依赖上层协议的 BER 测试；
- `Comma Detect and Align` 为 8B/10B 数据寻找字符边界。

因此：

```text
CDR Lock ≠ Comma/Block Aligned ≠ Lane Up ≠ Protocol Link Up
```

这些分别属于模拟采样、PCS 对齐、多 Lane 初始化和上层协议状态。

### 4. Decoder 与 Block Alignment

图中可以看到两类主要路径：

- 8B/10B Decoder 路径；
- 128B/130B Decoder 与 Block Detect/Align 路径。

使用哪条路径由协议和 Wizard 配置决定。64B/66B 等协议还可能把部分同步、扰码或协议处理放在 GT 外部 IP 中。

### 5. RX Elastic Buffer

RX Elastic Buffer 位于恢复时钟相关数据路径与用户接口之间，主要用于：

- 隔离时钟相位差；
- 吸收允许范围内的频率偏差；
- Clock Correction；
- Channel Bonding。

它不是任意 CDC 的通用异步 FIFO。只有协议定义了可插入或删除的 Clock Correction Sequence 时，Buffer 才能长期吸收两端参考时钟的 ppm 偏差。

### 6. Gearbox 与 RX Interface

RX Sync/Async Gearbox 完成内部数据块与用户接口宽度之间的转换，最终由 `RX Interface` 输出 `RXDATA`、`RXCTRL*` 等信号。

`RXUSRCLK2` 通常是用户读取该接口的主要时钟。若数据需要进入系统时钟域，还应在 GT 外部进行明确的 CDC 设计。

## 复位结构

GT 内部不是一个统一复位域。UG576 将 RX 分为多个可复位区域：

- RX PMA；
- RX DFE/LPM；
- Eye Scan；
- RX PCS；
- RX Buffer。

![UG576 Figure 2-24：GTH RX Reset State Machine](assets/Xilinx-GT结构/ug576-fig2-24-rx-reset.png)

> 图 5：UltraScale GTH RX Reset State Machine。裁自 UG576 v1.7.1 Figure 2-24。

在 Sequential Mode 下，`GTRXRESET` 触发完整 RX 初始化。状态机依次处理 PMA、DFE/LPM、Eye Scan、PCS 与 Buffer，最终使 `RXRESETDONE` 置位。

图中最容易忽略的是 `RXUSERRDY`：

- RX PMA 可以先完成初始化；
- 状态机在进入 PCS 相关阶段前需要用户时钟稳定；
- 用户逻辑准备好接收数据后，才能置位 `RXUSERRDY`；
- 最终的 `RXRESETDONE` 不包含协议训练和 Block/Lane Alignment。

所以工程上应区分：

| 状态 | 表示什么 |
| --- | --- |
| `CPLLLOCK/QPLLLOCK` | PLL 频率进入规定锁定范围 |
| `RXPMARESETDONE` | RX PMA 复位阶段完成 |
| `RXRESETDONE` | GT RX 内部顺序复位完成 |
| Byte/Block Aligned | PCS 已找到字符或块边界 |
| Lane/Channel Up | 多 Lane 或 Aurora 等链路初始化完成 |
| Link Up | PCIe/Ethernet 等协议训练完成 |

完整上电顺序、各局部复位的使用边界、Buffer Bypass 对齐和系统级控制 FSM 见 [[Xilinx GT复位与初始化]]。

## DRP、Loopback 与调试结构

### DRP

Dynamic Reconfiguration Port 用于访问 Channel/Common 配置寄存器：

```text
DRPCLK, DRPADDR, DRPDI, DRPDO, DRPEN, DRPWE, DRPRDY
```

典型用途包括切换 Line Rate、修改 PLL、调整 TX FIR、调整 RX Equalizer 和读取监测状态。

DRP 写入只改变寄存器。配置能否安全生效，还取决于是否执行了对应的 PLL/TX/RX Reset、CDR 重新锁定和协议重新训练。

### Loopback

从 TX/RX 原图中的回环连线可以看出，GT 支持不同层次的内部回环：

- Near-End PCS Loopback；
- Near-End PMA Loopback；
- Far-End PMA Loopback；
- Far-End PCS Loopback。

不同回环经过的模块不同，因此用于隔离不同故障范围。底层验证通常按以下顺序进行：

1. Reference Clock 与 PLL Lock；
2. Reset Done 与 User Clock；
3. Near-End PCS/PMA Loopback；
4. PRBS Generator/Checker；
5. 外部短通道；
6. 真实板级通道；
7. 上层协议训练。

## 各代际结构差异

| 特征 | 7 Series GTX/GTH | UltraScale GTH/GTY | GTM |
| --- | --- | --- | --- |
| 主要组织 | 四 Channel Quad | 四 Channel Quad | Dual/Quad，依代际 |
| Channel Primitive | 有 | 有 | UG581 中无独立 Channel Primitive |
| Channel PLL | 每 Channel CPLL | 每 Channel CPLL | LCPLL 等新结构 |
| 共享 PLL | 一个 QPLL | QPLL0 与 QPLL1 | LCPLL，共享范围不同 |
| 调制 | NRZ | NRZ | NRZ/PAM4 |
| PCS | 编解码、对齐、Buffer | 增加多种 Gearbox/PCIe 路径 | 更偏向超高速 Ethernet 数据路径 |

这张表只用于建立结构差异，不能用于推导具体 Line Rate 或属性设置。

## 工程阅读方法

面对一个 GT 工程，建议按以下顺序追踪：

1. 确认器件与实际 Primitive：`GTXE2`、`GTHE2/3/4`、`GTYE3/4` 或 `GTM_*`。
2. 确认 Channel 所在 Dual/Quad 和参考时钟来源。
3. 确认 TX/RX 分别使用 CPLL、QPLL0 还是 QPLL1。
4. 沿 `REFCLK → PLL → Divider → OUTCLK → BUFG_GT → USRCLK` 检查时钟。
5. 沿 TX 原图从右向左追踪发送路径。
6. 沿 RX 原图从左向右追踪接收路径。
7. 检查 Buffer 是否启用，以及是否需要 Phase Alignment。
8. 区分 PLL Lock、Reset Done、Alignment 和 Link Up。
9. 最后检查 DRP、PRBS、Loopback 和上层协议状态。

## 参考资料

- AMD, [7 Series FPGAs GTX/GTH Transceivers User Guide, UG476 v1.12.1](https://docs.amd.com/v/u/en-US/ug476_7Series_Transceivers), 2018-08-14.
- AMD, [UltraScale Architecture GTH Transceivers User Guide, UG576 v1.7.1](https://docs.amd.com/v/u/en-US/ug576-ultrascale-gth-transceivers), 2021-08-18.
- AMD, [UltraScale Architecture GTY Transceivers User Guide, UG578 v1.4](https://docs.amd.com/v/u/en-US/ug578-ultrascale-gty-transceivers), 2025-12-19.
- AMD, [Virtex UltraScale+ FPGAs GTM Transceivers User Guide, UG581 v1.3](https://docs.amd.com/v/u/en-US/ug581-ultrascale-gtm-transceivers), 2020-05-21.

## Tags

`FPGA` `Xilinx` `AMD` `GT` `SerDes` `GTX` `GTH` `GTY` `GTM` `PMA` `PCS`

## See Also

- [[Xilinx GT调试经验]]：按时钟、复位、状态、Loopback、PRBS、IBERT 和 Eye Scan 分层定位 GT 问题。
- [[Xilinx GT复位与初始化]]：PLL、PMA、PCS、User Clock、Buffer Bypass 和协议复位的依赖顺序。
