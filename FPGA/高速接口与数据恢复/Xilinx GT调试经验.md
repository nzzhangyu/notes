# Xilinx GT 调试经验

> 核心原则：先把“不通”描述成可观测状态，再用 Example Design、Loopback、IBERT 和最小业务设计逐层改变测试边界；先定位故障属于用户逻辑、GT 数字部分、GT 模拟部分还是外部链路，最后才调整模拟参数。

## 背景与范围

本文整理 AMD/Xilinx 高速串行收发器的通用调试方法，主要适用于：

- 7 Series GTX/GTH；
- UltraScale/UltraScale+ GTH/GTY；
- Vivado Transceivers Wizard 或基于 GT 的协议 IP。

不同器件代际、Wizard 版本和协议 IP 暴露的端口名称不同。本文使用的 `CPLLLOCK/QPLLLOCK`、`TXRESETDONE/RXRESETDONE`、`RXBYTEISALIGNED` 等名称表示对应层次的典型状态，实际工程应以生成文件和所属 User Guide 为准。

本文不展开 GT 内部结构，结构与数据路径见 [[Xilinx GT结构]]；不覆盖 GTM/PAM4 的专有调试流程。

## 结论摘要

- `PLLLOCK`、`RESETDONE`、Alignment 和 Link Up 属于不同层次，前一层正常不能证明后一层正常。
- 优先保留 Wizard Example Design 的时钟、复位和初始化辅助逻辑，不要只复制 GT Primitive。
- Near-End PMA、外部回环和 Far-End PMA 能改变测试边界，是隔离 GT 内部与外部链路问题的关键工具。
- IBERT 用于物理层测量和参数扫描，但 IBERT 通过不能替代正式业务配置验证。
- PRBS 零误码不等于 `BER=0`；必须记录测试位数、时间、参数和置信上限，并用人工注错验证检查器有效。
- 调试系统应保存 Sticky Error、累计计数和故障快照，不能只看瞬时状态。

## 证据边界

| 类型 | 内容 | 使用方式 |
| --- | --- | --- |
| 官方资料 | UG476、UG576、UG578 对时钟、复位、PRBS、Loopback 和 Eye Scan 的定义 | 作为器件行为和限制的主要依据 |
| 官方工具资料 | PG168、PG182、UG908 对 Wizard Example Design、reset helper 和 IBERT 的说明 | 作为推荐工具流程的依据 |
| 工程经验 | 知乎《Xilinx 7系列GTX的初步问题定位方法》提出的 Example Design → IBERT → 回环 → 眼图五步法 | 作为排障顺序参考，不作为器件强制要求 |
| 工程推断 | 根据测试覆盖范围建立故障判断矩阵 | 需要在具体板卡上通过对照实验确认 |

## 一、先定义故障现象

不要只记录“GT 不通”。开始调试前，至少回答以下问题：

| 层次 | 需要描述的现象 |
| --- | --- |
| 参考时钟与 PLL | REFCLK 是否存在；CPLL/QPLL 是否锁定；是否发生掉锁 |
| GT 初始化 | `TXRESETDONE/RXRESETDONE` 是否拉高；上电时间是否稳定 |
| RX 恢复 | CDR 是否稳定；`RXOUTCLK` 是否符合预期 |
| PCS 对齐 | Byte/Word/Block Alignment 是否完成；是否反复重对齐 |
| 编码与数据 | 是否存在 8B/10B、PRBS、CRC 或帧错误 |
| Lane/协议 | Lane Up、Channel Up、Link Up 卡在哪一级 |
| 运行条件 | 必现、偶发、温度相关、速率相关还是上电次序相关 |

建议把问题写成可以证伪的描述，例如：

> 上电后 `QPLLLOCK=1`，`TXRESETDONE=1`，但 `RXRESETDONE` 偶发不能拉高；重新触发 RX datapath reset 后恢复。

这样的现象可以直接引导到 RX 时钟、复位状态机和输入信号条件，而不是盲目修改 TX FIR。

## 二、建立三套测试基线

### 1. Wizard Example Design

Example Design 用于验证：

- IP 配置和参考时钟选择；
- PLL、OUTCLK 和 User Clock；
- 推荐的 TX/RX 复位顺序；
- Buffer 或 Buffer Bypass 辅助流程；
- 基本数据发生、检查和状态监测。

推荐先完成仿真，再将 Example Design 作为独立工程上板。若 Example Design 正常而用户工程异常，优先检查集成差异，而不是先怀疑器件或链路。

需要对比的配置包括：

- Line Rate、Reference Clock、CPLL/QPLL；
- TX/RX datapath width 和 User Clock；
- 8B/10B、Gearbox、Buffer 和 Clock Correction；
- TX/RX Equalization；
- Reset Helper、User Clock Helper 和 Buffer Bypass Controller。

### 2. IBERT

IBERT 用于：

- 产生和检查 PRBS；
- 统计错误并估算 BER；
- 设置内部 Loopback；
- 扫描 TX Swing、Pre/Post-cursor 和 RX Equalization；
- 运行 2D Eye Scan 或 Bathtub Scan。

IBERT 是物理层测试基线，但其 GT 配置可能不同于正式工程。使用测试结论前，应记录并比较两者的 Line Rate、REFCLK、PLL、TX/RX 参数和 Loopback 模式。

### 3. 最小业务设计

建议在正式工程中保留一个不依赖复杂协议的测试模式：

```text
Pattern/PRBS Generator
        ↓
  正式工程 GT 配置
        ↓
  实际板级物理链路
        ↓
Pattern/PRBS Checker
        ↓
错误计数、掉锁次数、状态快照
```

它使用与业务相同的 GT 和时钟配置，但绕开复杂协议状态机，用来填补 Example Design、IBERT 与最终业务工程之间的验证空白。

## 三、按时钟链逐级检查

![UG576 Figure 2-11：Internal Channel Clocking Architecture](assets/Xilinx-GT结构/ug576-fig2-11-channel-clocking.png)

> UltraScale GTH Channel 时钟结构，裁自 UG576 v1.7.1 Figure 2-11。调试时应沿实际器件的对应时钟路径检查。

建议按以下顺序追踪：

```text
外部 MGTREFCLK
    → Reference Clock Buffer/Distribution
    → CPLL 或 QPLL/QPLL0/QPLL1
    → TX/RX Clock Divider
    → TXOUTCLK/RXOUTCLK
    → BUFG_GT/User Clock Helper
    → TXUSRCLK(2)/RXUSRCLK(2)
```

### 时钟检查清单

- REFCLK 频率、引脚和 Wizard 配置一致。
- PLL 的 VCO 和输出分频组合支持目标 Line Rate。
- TX 与 RX 实际选择了预期的 CPLL/QPLL。
- `TXOUTCLK/RXOUTCLK` 频率与 Line Rate、内部数据宽度一致。
- `TXUSRCLK(2)/RXUSRCLK(2)` 在 `TXUSERRDY/RXUSERRDY` 有效前已经稳定。
- 多 Lane 共享 QPLL 时，单 Lane 恢复动作不会误复位整个 Quad。
- 动态切换 REFCLK、PLL、Line Rate 或 datapath width 后执行了该配置要求的重初始化。

`PLLLOCK=1` 只说明 PLL 已进入规定锁定范围，不代表 TX/RX 数据路径、CDR、Alignment 或上层协议已经可用。

## 四、严格管理复位与初始化

![UG576 Figure 2-24：GTH RX Reset State Machine](assets/Xilinx-GT结构/ug576-fig2-24-rx-reset.png)

> UltraScale GTH RX 顺序复位状态机，裁自 UG576 v1.7.1 Figure 2-24。7 Series 与不同 Wizard 版本的具体端口和步骤应分别核对。

通用初始化依赖关系可以概括为：

```text
电源与 REFCLK 稳定
    → 复位并启动 CPLL/QPLL
    → 等待 PLLLOCK
    → 建立 OUTCLK 和 User Clock
    → 置位 USERRDY
    → 完成 TX/RX PMA、PCS 和 Buffer 复位
    → 等待 RESETDONE
    → 完成 Alignment/Training
    → 上层协议进入 Link Up
```

### 复位经验

- 优先使用 Wizard 生成的 reset helper，不让多个业务模块直接驱动底层 GT reset。
- 为复位请求设置统一仲裁、超时、失败状态码和重试上限。
- 区分 PLL reset、TX/RX datapath reset、PMA reset、PCS reset 和 Buffer reset。
- PLL 掉锁、参考时钟丢失或动态改速后，应明确设计重新初始化策略。
- 不要为了消除偶发错误而周期性复位整个 Quad；这可能掩盖根因并影响其他 Lane。
- `TXRESETDONE/RXRESETDONE` 表示 GT 内部复位完成，不包含协议训练和 Link Up。

PG182 指出，在部分 UltraScale Wizard reset helper 用法中，初始化完成后若关联 PLL 掉锁，done 指示会撤销，但复位序列不会自动重新开始，需要用户逻辑触发恢复。因此必须验证故障恢复路径，而不只是验证首次上电。

各复位信号的释放条件、局部恢复范围、Buffer Bypass 对齐以及系统级复位 FSM 见 [[Xilinx GT复位与初始化]]。

## 五、建立可追溯的状态观测

| 分类 | 典型观测项 | 能说明什么 | 不能单独证明什么 |
| --- | --- | --- | --- |
| 电源/时钟 | `GTPOWERGOOD`、`CPLLLOCK`、`QPLLLOCK`、REFCLK lost | 电源与 PLL 条件 | 数据正确、CDR 稳定 |
| 复位 | `TXRESETDONE`、`RXRESETDONE`、Wizard reset done | GT 初始化阶段完成 | Alignment、Link Up |
| Buffer | `TXBUFSTATUS`、`RXBUFSTATUS` | Overflow/Underflow 或状态异常 | 错误根因 |
| 对齐 | Byte/Word/Block/Lane aligned | PCS 找到边界 | Payload 正确 |
| 编码 | `RXDISPERR`、`RXNOTINTABLE` | 8B/10B 码组或 disparity 异常 | 是 SI、对齐还是 TX 数据问题 |
| PRBS | PRBS lock、`RXPRBSERR`、累计错误 | 测试模式下的位错误 | 业务协议正确 |
| 协议 | Lane Up、Channel Up、Link Up、CRC | 上层训练和帧状态 | 模拟裕量充足 |

### 不要只看瞬时电平

偶发故障至少应保留：

- Sticky Error；
- 累计错误计数；
- 掉锁、重对齐和复位次数；
- 第一次错误时间戳；
- 错误时的关键状态快照；
- ILA 触发前后的状态历史。

异步状态进入统计逻辑或 ILA 时应按其语义进行 CDC 处理；单比特电平、多比特状态和窄脉冲不能使用同一种同步方法。

## 六、用四种 Loopback 改变测试边界

### 7 Series GTX/GTH 的编码

UG476 v1.12.1 定义：

| `LOOPBACK[2:0]` | 模式 | 主要诊断价值 |
| --- | --- | --- |
| `000` | Normal Operation | 正常外部链路 |
| `001` | Near-End PCS Loopback | 检查本端 PCS 数字路径 |
| `010` | Near-End PMA Loopback | 检查本端 GT，覆盖更多 PMA 路径 |
| `100` | Far-End PMA Loopback | 让对端在 PMA 层返回接收数据 |
| `110` | Far-End PCS Loopback | 让对端经过 RX/TX PCS 后返回数据 |

其余编码在该器件文档中为 Reserved。其他系列也支持类似测试结构，但端口宽度、编码、可用条件和切换复位要求必须查对应 User Guide，不能直接套用 UG476。

### 1. Near-End PCS

```text
本端 TX PCS ─────────→ 本端 RX PCS
             绕过大部分 PMA 和外部链路
```

适合验证数字路径。通过后不能证明 TX Driver、RX AFE、CDR、光模块、线缆或 PCB 正常。

### 2. Near-End PMA

```text
本端 TX PCS → TX PMA
                 ↓ 内部回环
本端 RX PCS ← RX PMA
```

适合建立本端 GT 基线。如果 Near-End PCS 正常而 Near-End PMA 失败，优先检查 PLL、PMA、CDR、复位条件和相关配置。

进入或退出某些 PMA Loopback 后需要重置 RX。具体要求依器件系列而异，例如 UG576 明确给出了 GTH Loopback 相关复位要求，应按实际目标器件执行。

### 3. Far-End PMA

```text
测试端 TX → 外部通道 → 对端 RX PMA
                              ↓ 回环
测试端 RX ← 外部通道 ← 对端 TX PMA
```

适合测试双向物理链路以及两端 GT PMA。它比用户逻辑回环引入的数字逻辑更少，通常更适合隔离板级通道问题。

### 4. Far-End PCS

```text
测试端 TX → 外部通道 → 对端 RX PMA → RX PCS
                                           ↓ 回环
测试端 RX ← 外部通道 ← 对端 TX PMA ← TX PCS
```

覆盖对端更多 PCS 路径，但可用条件通常更多。UG476 说明某些 Gearbox 配置不支持 Far-End PCS；使用前必须检查目标协议、Buffer、Clock Correction 和时钟条件。

### 推荐的环回顺序

```text
Near-End PCS
    → Near-End PMA
    → 外部短通道回环
    → 完整板级通道
    → Far-End PMA/PCS
    → 上层协议回环
```

测试顺序不是强制要求。其价值在于每一步只增加一部分硬件或逻辑，使失败边界可解释。

## 七、PRBS 与 BER 测试

### PRBS 使用清单

- TX 与 RX 选择相同的 PRBS 多项式。
- 切换 PRBS 或 Loopback 后，等待链路稳定再清零计数。
- 记录是否使用反相、Polarity 反转以及协议 Scrambler。
- 先用 PRBS7 验证基本路径，再根据目标使用 PRBS31 等更长模式施加压力。
- 测试开始后执行一次 `TXPRBSFORCEERR` 或等效人工注错。
- 确认错误计数增加，再清零并开始正式测试。

人工注错用于验证 Checker、Lane 映射、计数读取和清零链路确实有效。如果注错不能被发现，“零误码”没有诊断意义。

### 零误码的表达

测试位数为：

\[
N = R_{\text{line}} \times T
\]

其中 \(R_{\text{line}}\) 为 Lane Line Rate，\(T\) 为有效测试时间。零误码不应写成 `BER=0`。在独立误码的简化统计假设下，零误码时 95% 置信度的 BER 上限可近似写为：

\[
BER_{95\%} \lesssim \frac{3}{N}
\]

例如测试报告应写：

> 10.3125 Gb/s，PRBS31，连续测试 3600 s，观测到 0 bit error；在简化统计假设下，95% 置信 BER 上限约为 \(8.1\times10^{-14}\)。

这个上限不是器件保证值；若协议、误码相关性或测试停顿不满足假设，应采用适合项目的统计模型。

## 八、IBERT 与 Eye Scan

UG908 中的 Vivado Serial I/O Analyzer 可通过 IBERT 创建 Link、修改 Link 属性并运行扫描。典型用途包括：

- 比较 Lane 之间的接收裕量；
- 比较不同通道、模块或线缆；
- 扫描 TX Swing、Pre/Post-cursor；
- 比较 RX LPM/DFE 或其他均衡设置；
- 运行 2D Eye Scan 或 Bathtub Scan。

### 使用原则

- 先保存 Baseline，再单变量扫描。
- 每次扫描记录器件、Lane、Line Rate、REFCLK、PLL、PRBS、Loopback 和 TX/RX 参数。
- 不只保留截图，同时保存扫描配置和原始结果。
- 调参改善只能说明该参数与当前条件相关，不能自动成为已确认根因。
- 找到较优参数后，必须回到正式业务配置进行长时间复测。

### Eye Scan 不等于示波器眼图

GT 内部 Eye Scan 反映内部采样器在当前接收、均衡和判决设置下看到的裕量；示波器眼图反映外部测量点的电压波形。两者的测量位置、均衡影响、带宽和误差来源不同，不能直接用面积或开口做一一对应。

UltraScale/UltraScale+ 可结合 In-System IBERT 在业务设计中进行支持范围内的 2D Eye Scan；该功能不应泛化到 7 Series，具体支持范围以 PG246 和所用 Vivado 版本为准。

## 九、测试结果与故障范围

| Example Design | IBERT | Near-End PMA | 外部/Far-End 回环 | 优先检查 |
| --- | --- | --- | --- | --- |
| 仿真失败 | 未测 | 未测 | 未测 | IP 参数、时钟比例、复位或仿真环境 |
| 上板失败 | 正常 | 正常 | 正常 | Example Design/用户工程集成差异 |
| 失败 | 失败 | 失败 | 失败 | REFCLK、PLL、电源、复位或 GT 配置 |
| 正常 | 正常 | 正常 | 失败 | 外部通道、连接器、模块、线缆或对端 |
| 正常 | 正常 | 正常 | 正常 | 协议、CDC、帧同步、流控或业务逻辑 |
| 单 Lane 异常 | 其他 Lane 正常 | 视结果而定 | 异常 | Lane 专属通道、端口或参数 |
| 多 Lane 同时掉线 | 同时异常 | 可能正常 | 同时异常 | 共享 REFCLK、QPLL、电源或公共复位 |

该表用于确定下一步，不是直接判定根因。例如 Near-End PMA 失败仍需通过时钟、复位状态和器件替换等证据区分配置问题与硬件问题。

## 十、推荐调试流程

### 阶段 A：静态核对

1. 记录器件、Vivado、Wizard/IP 版本。
2. 对比 Example Design 与业务工程参数。
3. 核对 REFCLK、PLL、Line Rate 和 User Clock。
4. 核对复位、Buffer、Alignment 和协议配置。

### 阶段 B：最小链路

1. 运行 Example Design 仿真。
2. Example Design 独立上板。
3. 检查 PLL、Reset Done 和状态机卡点。
4. 执行 Near-End PCS/PMA。
5. 执行 PRBS 人工注错和短时 BER 测试。

### 阶段 C：扩大测试边界

1. 外部短通道回环。
2. 完整板级通道。
3. Far-End PMA/PCS。
4. 比较 Example Design 与 IBERT。
5. 必要时执行 Eye Scan 和单变量参数扫描。

### 阶段 D：业务验证

1. 最小业务 Pattern/PRBS 模式。
2. 协议训练和 Link Up。
3. 满负载、长时间和边界条件测试。
4. 验证掉锁、重同步和复位恢复。
5. 固化状态计数、测试参数和结论。

## 十一、常见错误做法

- 看到 `PLLLOCK=1` 就认为 GT 链路正常。
- 看到 `RESETDONE=1` 就认为协议已经 Link Up。
- Near-End PCS 通过后就宣布 PMA 和外部链路正常。
- 只在完整业务工程中调试，不保留已知正确基线。
- IBERT 与业务工程使用不同的 Line Rate、PLL 或均衡参数，却直接比较结果。
- 切换 Loopback、PLL 或 Line Rate 后不执行文档要求的复位。
- PRBS 零误码测试没有人工注错。
- 只测试几秒，或者不记录有效测试位数。
- 同时修改多个 TX/RX 模拟参数。
- 只保存 Eye Scan 截图，不保存配置和原始数据。
- 只观察瞬时信号，不保存 Sticky Error 和故障快照。
- 用周期性复位掩盖掉锁、Buffer 或 CDC 问题，并把它误写成根因修复。

## 十二、现场记录模板

```markdown
## GT 调试记录：<问题名称>

### 环境
- FPGA/Speed Grade：
- Board Revision：
- Vivado/Wizard/IP：
- Lane/Quad：
- Line Rate：
- REFCLK：
- PLL：
- Encoding/Gearbox：
- Buffer/Clock Correction：

### 现象
- 触发条件：
- 稳定复现步骤：
- 首次异常时间：
- 影响范围：

### 状态快照
- PLL/REFCLK：
- TX/RX Reset：
- Buffer：
- Alignment：
- PRBS/Encoding：
- Protocol：

### 测试
| 测试边界 | 配置 | 时间/位数 | 错误 | 结果 |
| --- | --- | ---: | ---: | --- |
| Example Design |  |  |  |  |
| Near-End PCS |  |  |  |  |
| Near-End PMA |  |  |  |  |
| 外部回环 |  |  |  |  |
| Far-End PMA/PCS |  |  |  |  |
| IBERT/Eye Scan |  |  |  |  |
| 业务链路 |  |  |  |  |

### 假设与证据
| 假设 | 支持证据 | 证伪测试 | 状态 |
| --- | --- | --- | --- |
|  |  |  | 待验证 |

### 结论
- 已确认根因：
- 修改：
- 相同条件复测：
- 遗留风险：
```

## FAQ

### IBERT 通过，为什么业务还是不通？

IBERT 主要验证 GT 与物理通道。业务工程还包含不同的复位、时钟、Buffer、编码、Alignment、CDC 和协议训练；还应确认 IBERT 与业务 GT 参数是否一致。

### `RXRESETDONE=1`，为什么仍然没有数据？

它只表示 GT RX 内部复位流程完成。还需要检查 CDR 稳定性、Byte/Block Alignment、Buffer、编码错误以及上层协议状态。

### 应该先调 TX 还是 RX 参数？

先建立默认 Wizard 参数下的 BER 和 Eye Scan 基线，再根据通道损耗、错误方向和扫描结果单变量调整。没有基线时，参数优化很难形成可复现结论。

## See Also

- [[Xilinx GT结构]]：GT Quad/Channel、PMA/PCS、时钟、复位和数据路径。
- [[Xilinx GT复位与初始化]]：完整上电、局部恢复、PLL 掉锁和 Buffer Bypass 的复位顺序。

## Tags

`FPGA` `Xilinx` `AMD` `GT` `GTX` `GTH` `GTY` `SerDes` `IBERT` `PRBS` `BER` `Eye Scan` `Loopback` `Debug`

## References

- AMD, [7 Series FPGAs GTX/GTH Transceivers User Guide, UG476 v1.12.1](https://docs.amd.com/v/u/en-US/ug476_7Series_Transceivers), 2018-08-14.
- AMD, [UltraScale Architecture GTH Transceivers User Guide, UG576 v1.7.1](https://docs.amd.com/v/u/en-US/ug576-ultrascale-gth-transceivers), 2021-08-18.
- AMD, [UltraScale Architecture GTY Transceivers User Guide, UG578](https://docs.amd.com/v/u/en-US/ug578-ultrascale-gty-transceivers).
- AMD, [7 Series FPGAs Transceivers Wizard LogiCORE IP Product Guide, PG168](https://docs.amd.com/r/en-US/pg168-gtwizard).
- AMD, [UltraScale FPGAs Transceivers Wizard LogiCORE IP Product Guide, PG182 v1.7](https://docs.amd.com/r/en-US/pg182-gtwizard-ultrascale), 2023-05-17.
- AMD, [Vivado Design Suite User Guide: Programming and Debugging, UG908](https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging).
- XTWL TPCL, [Xilinx 7系列GTX的初步问题定位方法](https://zhuanlan.zhihu.com/p/45883037), 2018-12-02；本文仅采用其调试工作流作为工程经验。
