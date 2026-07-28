# Xilinx FPGA Input Delay / Output Delay 工程实践

> `set_input_delay` 与 `set_output_delay` 的本质，是把 FPGA 芯片外部的数据产生、接收要求和板级互连关系纳入 Vivado 静态时序分析；对源同步接口，应分别计算 DATA 与转发 CLK 的传播延迟，再用二者的相对偏差建立 `-max/-min` 约束。

## 背景与范围

Vivado 可以分析 FPGA 内部寄存器、组合逻辑、时钟网络和 I/O 逻辑，但不会自动知道：

- ADC 在时钟边沿后多久输出数据；
- 接收端 FPGA 要求多少 setup/hold 时间；
- 信号经过 PCB、连接器和 FPC 后产生多少传播延迟；
- DATA 与 CLK 的板级延迟差、外部抖动和建模误差。

本笔记讨论 Xilinx FPGA 的常规同步并行接口和源同步接口，示例采用通用 Vivado XDC 语法。主要场景为：

```text
输入：ADC → ADC板PCB → 连接器/FPC → FPGA板PCB → Xilinx FPGA

输出：Xilinx FPGA_A → PCB_A → CON → PCB_B → Xilinx FPGA_B
```

其中 `CON` 表示两块 PCB 之间的一组板间连接器。输出案例不包含 FPC。

不在本文展开的内容：高速收发器、DDR PHY、异步数据恢复、CDR、眼图扫描和 BER 测试。器件系列与 Vivado 版本未指定，因此不讨论系列专用 I/O 原语。

## 结论摘要

- 必须先定义接口时钟及其参考点，再计算 I/O delay；脱离参考时钟谈“输入延迟”或“输出延迟”没有完整含义。
- 源同步输入的核心关系是 `tCO + DATA互连延迟 - CLK互连延迟`。
- 源同步输出的核心关系是接收端 `tSU/tH` 加上 DATA 与转发 CLK 的互连延迟差。
- `-max` 用于 setup 检查，描述最不利的晚到数据；`-min` 用于 hold 检查，描述最不利的早到数据。
- `set_output_delay -min` 常为负值。负值并不异常，它表示数据在接收时钟边沿之后仍需保持稳定。
- 不能只约束 `-max`。遗漏 `-min` 会使 hold 分析缺少外部接口要求。
- PCB 的绝对传播时间会影响跨板到达时刻，但在源同步约束中通常更关键的是 DATA 与 CLK 的相对传播偏差。
- 未经 PVT 覆盖和量测不确定度评估的单板实测值，只能作为工程观测，不能替代 datasheet 保证的 min/max 参数。

## 1. 约束目标与设计假设

### 1.1 三条时序边界

一个完整接口可分为三段：

```text
发送器内部时序 → 板级互连 → 接收器内部时序
```

对 ADC 输入 FPGA 的路径：

- 发送器内部时序：ADC 的 `tCO(min/max)`；
- 板级互连：ADC 板 PCB、连接器、FPC、FPGA 板 PCB；
- 接收器内部时序：由 Vivado 从 FPGA 输入端口继续分析到内部采样寄存器。

对 FPGA_A 输出至 FPGA_B 的路径：

- Vivado 在 FPGA_A 内部分析发送寄存器到输出端口；
- XDC 描述 `PCB_A + CON + PCB_B` 以及 FPGA_B 的 `tSU/tH`；
- FPGA_B 的输入寄存器要求作为 FPGA_A 的外部接收要求建模。

### 1.2 参数与符号

| 符号 | 含义 |
| --- | --- |
| `tCO_max/min` | 外部发送器时钟边沿到数据输出有效的最大/最小延迟 |
| `tSU` | 接收器在采样边沿前要求的数据稳定时间 |
| `tH` | 接收器在采样边沿后要求的数据保持时间 |
| `tDATA_max/min` | DATA 互连路径最大/最小传播延迟 |
| `tCLK_max/min` | 转发 CLK 互连路径最大/最小传播延迟 |
| `Usetup/Uhold` | 未单独纳入其他参数的外部不确定度和建模裕量 |

本笔记假定：

1. `tCO`、`tSU`、`tH` 均相对于所声明的有效时钟边沿；
2. DATA 和 CLK 的互连 min/max 已覆盖板材、温度、制造公差和路径差异；
3. `Usetup/Uhold` 不与 datasheet 或 Vivado 内部 clock uncertainty 重复计算；
4. 下文公式的时钟参考点位于 FPGA 端的转发时钟端口。若工程采用其他参考点，必须重新推导。

## 2. 时钟定义与时钟架构

### 2.1 `create_clock`、I/O delay 各自描述什么

| 约束 | 作用 |
| --- | --- |
| `create_clock` | 定义时钟周期、波形和时钟对象，使 Vivado 能建立 launch/capture 关系 |
| `set_input_delay` | 描述外部数据相对于参考时钟到达 FPGA 输入端口的时间范围 |
| `set_output_delay` | 描述 FPGA 输出端口必须为外部接收器预留的时序要求 |

I/O delay 不是 FPGA 输入缓冲器或输出缓冲器自身的延迟。FPGA 内部 I/O 路径由 Vivado 根据器件、布局布线和时序模型计算。

### 2.2 系统同步与源同步

**系统同步（system synchronous）**：发送端和接收端使用同一系统时钟源，但时钟到达两端可能经过不同路径。约束必须纳入公共时钟源到发送器、接收器的插入延迟差。

**源同步（source synchronous）**：发送端同时发送 DATA 和 CLK。接收端使用转发 CLK 采样 DATA。本文两个主要算例均采用此模型。

```text
发送器 ── DATA ──────────────> 接收器
       └─ forwarded CLK ─────> 接收器
```

在源同步接口中，若约束参考时钟定义在接收 FPGA 的 CLK 输入端口，则 DATA 的外部到达时间应包含 DATA 与 CLK 互连延迟之差，而不是只包含 DATA 的绝对延迟。

### 2.3 输入时钟定义示例

以下为 SDR 示例，假设转发时钟周期为 10 ns。差分时钟通常在 P 端口上创建时钟，具体端口名按工程修改。

```tcl
create_clock -name adc_dco -period 10.000 \
    [get_ports adc_dco_p]
```

定义时钟后，应检查 Vivado 是否识别了期望的时钟对象：

```tcl
report_clocks
report_clock_interaction
```

## 3. 输入时序约束：跨板 ADC 到 FPGA

### 3.1 路径模型

```text
ADC
 ├─ DATA → ADC板PCB → 连接器/FPC → FPGA板PCB → FPGA DATA端口
 └─ DCO  → ADC板PCB → 连接器/FPC → FPGA板PCB → FPGA CLK端口
```

ADC 在 DCO 有效边沿之后，以 `tCO` 定义的时间更新 DATA。由于 DATA 和 DCO 的板级路径不同，它们到达 FPGA 端口时会产生额外 skew。

### 3.2 `-max`：setup 方向

最不利的 setup 情况是：

- ADC 数据产生最晚：`tCO_max`；
- DATA 路径最慢：`tDATA_max`；
- CLK 路径最快：`tCLK_min`；
- 再加入未被其他参数覆盖的 setup 裕量：`Usetup`。

因此：

```text
InputDelay_max = tCO_max + tDATA_max - tCLK_min + Usetup
```

### 3.3 `-min`：hold 方向

最不利的 hold 情况是：

- ADC 数据产生最早：`tCO_min`；
- DATA 路径最快：`tDATA_min`；
- CLK 路径最慢：`tCLK_max`；
- 从最早到达边界中扣除 hold 方向裕量：`Uhold`。

因此：

```text
InputDelay_min = tCO_min + tDATA_min - tCLK_max - Uhold
```

`InputDelay_min` 可以为正、零或负，取决于数据相对于 FPGA 端参考时钟的最早到达位置。

### 3.4 输入 Timing Budget 算例

> 以下数值全部是假设，仅用于说明计算方法，不代表任何实际器件或板卡。

| 参数 | 假设值/ns | 说明 |
| --- | ---: | --- |
| `tCO_max` | 1.20 | ADC 最晚输出 |
| `tCO_min` | 0.40 | ADC 最早输出 |
| `tDATA_max` | 0.92 | DATA 互连最慢 |
| `tDATA_min` | 0.78 | DATA 互连最快 |
| `tCLK_max` | 0.82 | DCO 互连最慢 |
| `tCLK_min` | 0.70 | DCO 互连最快 |
| `Usetup` | 0.10 | setup 方向额外裕量 |
| `Uhold` | 0.10 | hold 方向额外裕量 |

计算：

```text
InputDelay_max = 1.20 + 0.92 - 0.70 + 0.10 = 1.52 ns
InputDelay_min = 0.40 + 0.78 - 0.82 - 0.10 = 0.26 ns
```

对应 XDC：

```tcl
set adc_data_ports [get_ports {adc_data_p[*]}]

set_input_delay -clock [get_clocks adc_dco] \
    -max 1.520 $adc_data_ports

set_input_delay -clock [get_clocks adc_dco] \
    -min 0.260 $adc_data_ports
```

如果总线各 bit 的路径差异明显，应按 byte/lane 或单独端口分组约束，不能用一个平均延迟覆盖全部信号。

### 3.5 何时可以使用简化公式

只有在下列条件成立时，才可近似写成：

```text
InputDelay_max ≈ tCO_max + board_skew_max
InputDelay_min ≈ tCO_min + board_skew_min
```

其中 `board_skew` 必须明确等于 DATA 路径延迟减 CLK 路径延迟，而不是 DATA 的绝对 PCB 延迟。若时钟参考点不在 FPGA 输入端口，或系统同步时钟存在独立路径，必须使用完整拓扑重新推导。

## 4. 输出时序约束：跨板 FPGA 到 FPGA

### 4.1 路径模型

```text
Xilinx FPGA_A
 ├─ DATA → PCB_A → CON → PCB_B → FPGA_B DATA端口
 └─ CLK  → PCB_A → CON → PCB_B → FPGA_B CLK端口
```

FPGA_A 需要保证 DATA 到达 FPGA_B 后，满足 FPGA_B 输入寄存器相对于转发 CLK 的 `tSU` 和 `tH` 要求。

### 4.2 `-max`：为接收端 setup 预留时间

最不利的 setup 情况是 DATA 最慢、CLK 最快：

```text
OutputDelay_max = tSU + tDATA_max - tCLK_min + Usetup
```

这个值告诉 Vivado：FPGA_A 内部从发送寄存器到输出端口的路径，必须给外部互连和 FPGA_B 的 setup 要求留下这么多时间。

### 4.3 `-min`：为接收端 hold 预留时间

最不利的 hold 情况是 DATA 最快、CLK 最慢：

```text
OutputDelay_min = tDATA_min - tCLK_max - tH - Uhold
```

当 `tH` 大于 DATA 与 CLK 的最小路径差时，`OutputDelay_min` 通常为负值。这是常见且合理的结果。

### 4.4 输出 Timing Budget 算例

> 以下数值全部是假设，仅用于说明计算方法。

| 参数 | 假设值/ns | 说明 |
| --- | ---: | --- |
| `tSU` | 0.80 | FPGA_B setup 要求 |
| `tH` | 0.20 | FPGA_B hold 要求 |
| `tDATA_max` | 0.65 | `PCB_A + CON + PCB_B` 数据路径最慢值 |
| `tDATA_min` | 0.55 | 数据路径最快值 |
| `tCLK_max` | 0.56 | 转发时钟路径最慢值 |
| `tCLK_min` | 0.48 | 转发时钟路径最快值 |
| `Usetup` | 0.10 | setup 方向额外裕量 |
| `Uhold` | 0.08 | hold 方向额外裕量 |

计算：

```text
OutputDelay_max = 0.80 + 0.65 - 0.48 + 0.10 = 1.07 ns
OutputDelay_min = 0.55 - 0.56 - 0.20 - 0.08 = -0.29 ns
```

应先为转发时钟建立正确的时钟对象。以下代码只展示约束结构，`<source_clock_pin>` 必须替换为工程中真正驱动转发时钟的源时钟引脚：

```tcl
create_generated_clock -name tx_fwd_clk \
    -source [get_pins <source_clock_pin>] \
    -divide_by 1 \
    [get_ports tx_clk_p]

set tx_data_ports [get_ports {tx_data_p[*]}]

set_output_delay -clock [get_clocks tx_fwd_clk] \
    -max 1.070 $tx_data_ports

set_output_delay -clock [get_clocks tx_fwd_clk] \
    -min -0.290 $tx_data_ports
```

`create_generated_clock` 的 `-source` 必须与真实 RTL、时钟资源及转发结构一致。不能仅因输出端口名相似而猜测源时钟关系。

### 4.5 关于 FPGA_B 的 `tSU/tH`

接收端也是 FPGA 时，`tSU/tH` 不一定像普通外设一样以一个固定常数直接列出。工程上可采用以下方式之一：

1. 由 FPGA_B 自己建立输入约束并完成 STA，以验证其内部采样能力；
2. 根据选定 I/O 标准、输入寄存器位置、时钟结构及器件 speed grade，从对应 Xilinx 文档或 Vivado 时序模型获得接收要求；
3. 将接口作为两端联合 Timing Budget 管理，明确 FPGA_A 输出预算与 FPGA_B 输入预算的边界。

在缺少器件系列、speed grade、I/O 结构和布局信息时，不应虚构固定的 FPGA 输入 `tSU/tH`。

## 5. DDR 接口的补充说明

DDR 接口在时钟上升沿和下降沿都传输数据，必须分别描述两个边沿。Vivado XDC 中通常需要 `-clock_fall` 和 `-add_delay`，例如：

```tcl
# 示例结构，数值需分别根据两个边沿的外部 timing budget 计算
set_input_delay -clock [get_clocks adc_dco] \
    -max <rise_max> [get_ports {adc_data_p[*]}]
set_input_delay -clock [get_clocks adc_dco] \
    -min <rise_min> [get_ports {adc_data_p[*]}]

set_input_delay -clock [get_clocks adc_dco] -clock_fall -add_delay \
    -max <fall_max> [get_ports {adc_data_p[*]}]
set_input_delay -clock [get_clocks adc_dco] -clock_fall -add_delay \
    -min <fall_min> [get_ports {adc_data_p[*]}]
```

若不使用 `-add_delay`，后写入的约束可能覆盖同一端口已有的另一边沿约束。两个边沿的 `tCO` 或有效窗口可能不同，不应默认使用相同数值。

## 6. 外部 Timing 参数获取与测量

### 6.1 从 datasheet 查找

优先查找器件 datasheet 的以下章节：

- Switching Characteristics；
- Timing Characteristics；
- Digital Output Timing；
- Interface Timing；
- AC Characteristics。

常见参数名称包括：

| 需求 | 可能的参数名 |
| --- | --- |
| 外部器件输出到 FPGA | `tCO`、Clock-to-Output、Data Output Delay、Clock-to-Data Skew |
| FPGA 输出到外部器件 | `tSU`、Setup Time、`tH`、Hold Time |

读取参数时必须同时确认：

- 参考的是上升沿还是下降沿；
- 测量阈值及负载条件；
- min、typ、max 哪些有保证；
- 适用的电压、温度、速率和工作模式；
- 参数是否已包含输出抖动或 lane-to-lane skew。

只有 typ 而没有 min/max 时，typ 不能直接作为量产约束边界。应优先向器件厂商索取完整 timing specification。

### 6.2 `tCO` 未知时的实测思路

**优先级 1：向厂商获取保证值。** 需要明确索取 `tCO_min`、`tCO_max`、参考边沿、测试条件和 PVT 范围。

**优先级 2：发送端测量。** 在 ADC 引脚附近同时测量 DCO 和 DATA，直接得到发送端的 clock-to-data 关系。发送端测量最接近器件 `tCO` 定义，但探测点仍可能包含封装和短走线影响。

**优先级 3：接收端测量。** 在 FPGA 端测量 DCO 和 DATA，得到的是：

```text
观测值 = tCO + tDATA - tCLK + 测量误差
```

若希望反推 `tCO`，必须有独立的 DATA/CLK 互连延迟或 skew 估计，且要扣除探头通道偏差。

### 6.3 示波器测量要求

- 差分接口使用合适的差分探头；不要把普通探头地夹接到差分 N 端。
- 示波器与探头带宽应足以保留被测边沿，带宽不足会改变交叉时刻和抖动观测。
- 测量前执行两个通道的 probe deskew；通道间几十皮秒偏差即可显著影响高速接口结论。
- CLK 和 DATA 应采用与器件规范一致的阈值定义。
- 优先使用可重复的测试码型，使数据翻转与时钟边沿之间的对应关系清晰。
- 覆盖多块样品、电压和温度条件，并记录测量不确定度。

实测结果应标为“观测范围”，而非未经证明的器件保证值。若只能得到有限样本，应在 Timing Budget 中增加合理裕量并保留待确认项。

## 7. PCB、FPC 与连接器互连延迟

### 7.1 完整互连模型

输入案例：

```text
tINTERCONNECT = tPCB_ADC + tCON1 + tFPC + tCON2 + tPCB_FPGA
```

输出案例：

```text
tINTERCONNECT = tPCB_A + tCON + tPCB_B
```

应分别为 DATA 和 CLK 建立该模型，并给出 min/max，而不是只计算一条“典型总长度”。过孔、封装逃线和连接器内部路径在精度要求较高时也应纳入。

### 7.2 早期经验估算

FR-4 走线常见传播延迟可在约 `5～7 ps/mm` 的数量级，`6 ps/mm` 可用于方案早期粗估：

```text
100 mm × 6 ps/mm ≈ 600 ps
```

这不是通用常数。实际值取决于叠层、有效介电常数、microstrip/stripline 结构、铜厚、线宽及参考平面。FPC 也不能未经确认就永久套用同一个经验值。

### 7.3 具体计算与测量方法

| 阶段 | 方法 | 适用目的 | 主要限制 |
| --- | --- | --- | --- |
| 方案阶段 | 长度 × 经验传播延迟 | 数量级估算、早期预算 | 精度有限，不覆盖连接器和材料差异 |
| PCB 设计 | 基于叠层的场求解器 | 获得每层单位长度延迟 | 依赖准确叠层和材料参数 |
| 布线完成 | EDA 提取实际 etch length/delay | 获得 DATA/CLK 路径差 | 需确认是否包含过孔、封装和连接器 |
| 连接器/FPC | 厂商模型、S 参数或延迟规格 | 纳入非 PCB 互连 | 型号、频率和安装条件必须匹配 |
| 样机阶段 | TDR | 观察阻抗不连续和传播时间 | 端接、夹具与参考面会影响结果 |
| 频域验证 | VNA/S 参数 | 分析损耗、群时延和反射 | 需要去嵌和相应 SI 能力 |
| 运行波形 | 高速示波器 | 验证接收端 clock-data 关系 | 受探头负载、deskew 和统计覆盖限制 |

### 7.4 min/max 的建立

每条路径至少应记录：

| 项目 | DATA min | DATA max | CLK min | CLK max | 依据 |
| --- | ---: | ---: | ---: | ---: | --- |
| 发送端 PCB |  |  |  |  | EDA/场求解 |
| 连接器 |  |  |  |  | 厂商模型/测量 |
| FPC（如有） |  |  |  |  | 厂商资料/测量 |
| 接收端 PCB |  |  |  |  | EDA/场求解 |
| 合计 |  |  |  |  | min/max 汇总 |

不要把所有段的统计误差无条件线性相加，也不要在没有依据时假设误差完全抵消。量产约束应采用与工程可靠性目标一致的 worst-case 或经过验证的统计模型。

## 8. 不确定度的处理

可能需要纳入外部预算的因素包括：

- ADC 输出抖动或 clock-to-data jitter；
- DATA/CLK lane-to-lane skew；
- PCB/FPC 材料与制造公差；
- 连接器、温度和电压变化；
- 测量误差及模型误差。

Vivado 内部时钟不确定度、器件内部 PVT 模型与外部 `Usetup/Uhold` 的边界必须明确。重复计入会造成过度保守，遗漏则会产生虚假裕量。

如需显式设置时钟不确定度，应先确认其对象和物理含义，例如：

```tcl
# 示例：数值必须来自实际抖动预算，不能直接照抄
set_clock_uncertainty -setup <setup_uncertainty> [get_clocks adc_dco]
set_clock_uncertainty -hold  <hold_uncertainty>  [get_clocks adc_dco]
```

若某项已包含在 `tCO_max/min` 或 I/O delay 裕量中，就不应再次通过 `set_clock_uncertainty` 重复加入。

## 9. 异步采样的适用边界

如果输入 DATA 与 FPGA 采样时钟之间没有固定相位或频率关系，传统的 source-synchronous `set_input_delay` 模型通常不能完整描述接口可靠性。此时主要问题会转向同步器、过采样、数据恢复和采样窗口。

不能仅为清除时序违例而对输入使用 `set_false_path`。任何 timing exception 都必须有功能上的依据，并说明该路径由何种结构或验证方法保证。异步数据恢复的详细设计与验证应独立成文。

## 10. Vivado 检查方法

### 10.1 基础报告

```tcl
report_clocks
report_clock_interaction
report_exceptions
check_timing -verbose
report_timing_summary
```

### 10.2 重点检查项

- 输入/输出端口是否同时具有 `-max` 和 `-min`；
- 时钟对象是否绑定到正确端口或 generated clock 源；
- DDR 的上升沿和下降沿约束是否都存在；
- 端口通配符是否实际匹配预期对象；
- 是否存在未约束输入、输出或时钟；
- 是否有重复、覆盖或过宽的约束；
- setup 和 hold 报告中的 launch/capture 边沿是否符合接口协议；
- I/O 路径是否采用了预期的 I/O 标准、寄存器位置和时钟资源。

检查端口集合时，可在 Tcl Console 中确认匹配数量：

```tcl
set adc_data_ports [get_ports {adc_data_p[*]}]
puts "ADC data port count = [llength $adc_data_ports]"
```

若结果为 0，应修正对象表达式，不能假定约束已经生效。

## 11. 工程工作流

1. 明确接口属于系统同步、源同步还是异步关系。…29658 tokens truncated…s.amd.com/v/u/en-US/xapp1252-burst-clk-data-recovery) | v1.3，2019-04-12 | GTH/GTY 突发模式 CDR、快速且有界的锁定时间 | 适合需要 burst-mode 快速锁定的高速链路 |
| [XAPP1277：Burst Clock Data Recovery for PON](https://docs.amd.com/r/en-US/xapp1277-burst-clk-data-rec-pon-apps-ultrascale/Summary) | v1.2，2024-01-05 | 1.25/2.5 Gb/s PON、同步过采样、突发数据恢复 | 面向 PON/光接入应用，通用性低于 XAPP1240 |
| [XAPP1248：Receiving SD-SDI](https://docs.amd.com/r/en-US/xapp1248-smpte-sdi-ultrascale-gth-transceivers/Receiving-SD-SDI) | 在线文档 | GTH 对270 Mb/s SD-SDI进行11倍异步过采样，PL中的DRU恢复数据 | 可作为 XAPP1240/NIDRU 的具体应用案例 |

## 文档关系

```text
XAPP523
7 Series LVDS四倍异步过采样
       │
XAPP1294
轻量IDDR四倍过采样
       │
       ▼
XAPP1240
通用NIDRU、分数倍过采样、动态配置
       │
       ├──► XAPP1248：SD-SDI应用
       └──► XAPP1252/XAPP1277：突发模式CDR
```

## XAPP1240 为什么值得优先阅读

相较于 XAPP523/XAPP1294 的固定4倍采样结构，XAPP1240 的 NIDRU 更通用：

- 处理来自 SelectIO 或 SerDes 的解串过采样数据；
- 支持 fractional oversampling ratio；
- 数据率、输入 ppm 范围、jitter bandwidth 和 jitter peaking 可动态配置；
- 多通道可共用参考时钟，同时处理不同输入速率；
- 并行输出宽度可配置，便于连接8-bit或10-bit接口；
- 支持不中断业务数据的一维水平眼图扫描；
- 面向7 Series、UltraScale和Versal器件。

它不再只是简单的四状态采样点选择器，而是更完整的数字 CDR/NIDRU。

## 推荐阅读顺序

1. [[XAPP1294 基于IDDR的4倍异步过采样与DRU]]：理解 IDDR 四点采样、E4、FSM和bit skip。
2. [[XAPP523 7系列LVDS 4倍异步过采样与DRU]]：理解高速SelectIO、内部样本重映射、固定宽度输出和时钟校准。
3. XAPP1240：学习分数倍过采样、数字环路、动态配置和眼图扫描。
4. XAPP1252/XAPP1277：需要突发模式快速锁定时再读。

## 选择建议

| 需求 | 优先文档 |
| --- | --- |
| 继续学习通用数字过采样 CDR | XAPP1240 |
| 研究7 Series高速SelectIO四倍采样 | XAPP523 |
| 接收低于 GT 正常工作下限的 SD-SDI | XAPP1240 + XAPP1248 |
| 突发数据快速锁定 | XAPP1252 |
| PON 1.25/2.5 Gb/s 突发接收 | XAPP1277 |

## See Also

- [[基于IDDR的4倍异步过采样与数据恢复]]
- [[XAPP1294 基于IDDR的4倍异步过采样与DRU]]
- [[XAPP523 7系列LVDS 4倍异步过采样与DRU]]

## References

- AMD/Xilinx 官方文档库；上述版本与发布日期核对于2026-07-24。

## Tags

`FPGA` `Xilinx` `AMD` `CDR` `DRU` `Oversampling` `NIDRU` `SelectIO` `GTH` `GTY`
