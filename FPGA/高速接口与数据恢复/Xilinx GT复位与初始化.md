# Xilinx GT 复位与初始化

> GT 复位的本质是按依赖关系逐级建立电源、参考时钟、PLL、PMA、User Clock、PCS/Buffer 和协议状态；不要把所有高有效复位简单地同时撤销。

## 背景与范围

本文说明 AMD/Xilinx GT 的完整上电复位、局部复位、Buffer Bypass 对齐和运行期故障恢复，主要适用于：

- 7 Series GTX/GTH；
- UltraScale/UltraScale+ GTH/GTY；
- Vivado Transceivers Wizard 及基于 GT 的协议 IP。

不同器件代际、Wizard/IP 版本和配置会改变端口名称、有效条件、最小脉宽和对齐步骤。本文使用通用信号名表达依赖关系；具体实现必须以目标器件 User Guide、IP Product Guide 和生成的 Example Design 为准。

本文不覆盖 GTM/PAM4 专有流程，也不建议绕过 Wizard helper 直接拼接未经验证的 Primitive 复位时序。

## 结论摘要

- 主依赖是：`电源/REFCLK → PLLRESET → PLLLOCK → GTTXRESET/GTRXRESET → OUTCLK/USRCLK → USERRDY → RESETDONE → Delay/Phase Alignment → 协议复位`。
- `TXUSERRDY/RXUSERRDY`不是普通复位，而是“用户时钟与逻辑已准备好”的握手条件。
- `PLLLOCK`、`RESETDONE`、Alignment 和 Link Up 属于不同层次，不能相互替代。
- 首次上电和重大动态配置变化使用完整顺序复位；只有故障边界明确时才使用 PMA、PCS、CDR 或 Buffer 局部复位。
- 共享 QPLL 属于 Quad 级资源。复位 QPLL 会影响所有使用它的 Channel，单 Lane 恢复应优先使用 Lane 级 datapath reset。
- 优先使用 Wizard 生成的 Reset、User Clock 和 Buffer Bypass Helper；系统级 FSM 负责请求、仲裁、超时、重试和协议复位。

## 文档依据与证据边界

| 类型 | 依据 | 本文用途 |
| --- | --- | --- |
| 官方定义 | UG476、UG576、UG578 | 复位区域、顺序状态机、Loopback 和 Buffer Bypass 条件 |
| 官方 IP 流程 | PG168、PG182 | Wizard helper、Example Design、reset done 和故障恢复 |
| 工程建议 | 本文的超时、错误码和恢复边界 | 通用控制框架，需在具体项目验证 |

## 一、先区分复位层次

GT 内部不是一个统一复位域。应先判断要恢复哪一层：

| 层次 | 典型信号 | 影响范围 |
| --- | --- | --- |
| Shared PLL | `CPLLRESET`、`QPLLRESET` | CPLL 影响本 Channel；QPLL 可能影响 Quad 内多个 Channel |
| 完整 TX/RX datapath | `GTTXRESET`、`GTRXRESET` | 对应方向的 PMA、PCS 和相关内部区域 |
| PMA | `TXPMARESET`、`RXPMARESET` | 串行化、模拟前端、CDR或相关PMA路径 |
| PCS | `TXPCSRESET`、`RXPCSRESET` | 编码、Gearbox、对齐和并行数字路径 |
| RX 专用 | `RXCDRRESET`、`RXDFELPMRESET`、`EYESCANRESET` | CDR、Equalizer或Eye Scan局部功能 |
| Buffer | `RXBUFRESET`及器件对应信号 | Elastic Buffer和相关状态 |
| Delay/Phase Alignment | `TX/RXDLYSRESET`及相关控制 | Buffer Bypass后的延迟和相位对齐 |
| 上层协议 | Aurora/PCIe/Ethernet/自定义协议复位 | 训练、Lane绑定、帧和业务状态机 |

### 选择原则

```text
上电或PLL/速率重大变化
    → 完整顺序复位

PLL稳定，仅TX/RX通路异常
    → 对应方向datapath reset

已确认只在PCS/Buffer/CDR局部异常
    → 文档允许时执行局部复位
```

局部复位是缩小影响范围的恢复手段，不是完整上电初始化的替代品。

## 二、完整上电复位的依赖顺序

![UG576 Figure 2-11：Internal Channel Clocking Architecture](assets/Xilinx-GT结构/ug576-fig2-11-channel-clocking.png)

> UltraScale GTH Channel 时钟结构，裁自 UG576 v1.7.1 Figure 2-11。GT复位状态机会同时依赖Shared PLL、OUTCLK和User Clock。

### 总体流程

```text
保持全部复位
    ↓
等待电源、GTPOWERGOOD（若有）和REFCLK稳定
    ↓
释放CPLLRESET/QPLLRESET
    ↓
等待CPLLLOCK/QPLLLOCK
    ↓
释放GTTXRESET/GTRXRESET
    ↓
PMA开始初始化，OUTCLK逐步有效
    ↓
通过User Clock Helper建立USRCLK
    ↓
置位TXUSERRDY/RXUSERRDY
    ↓
PCS、Buffer等完成初始化
    ↓
等待TXRESETDONE/RXRESETDONE
    ↓
若Buffer Bypass：执行Delay/Phase Alignment
    ↓
等待DLYSRESETDONE/SYNCDONE等完成状态
    ↓
释放上层协议复位
    ↓
等待Byte/Block/Lane Alignment和Link Up
```

这个流程表达的是依赖关系，而不是规定所有信号必须在同一个管理时钟周期改变。

## 三、电源、REFCLK与PLL

### 初始保持

上电初期通常保持：

```text
CPLLRESET/QPLLRESET = 1
GTTXRESET/GTRXRESET = 1
protocol_reset      = 1
```

UltraScale/UltraScale+还应按器件要求等待`GTPOWERGOOD`。同时确认MGT参考时钟已经存在且稳定。

### 释放PLL复位

条件满足后：

```text
CPLLRESET = 0
```

或：

```text
QPLLRESET = 0
```

然后等待对应的`CPLLLOCK/QPLLLOCK`。

### 为什么PLL必须先完成

- TX PMA需要PLL提供高速串行时钟。
- RX和内部Clock Divider依赖选定的PLL及其稳定状态。
- PLL未锁定时释放数据通路，会使内部状态机在不确定时钟条件下运行。

不要只使用固定延迟猜测PLL何时可用。固定延迟可以满足文档要求的最小等待，但状态推进仍应检查`PLLLOCK`并设置超时。

### CPLL与QPLL影响范围

```text
CPLL Reset
    → 通常只影响所在Channel

QPLL Reset
    → 影响Quad内所有选择该QPLL的TX/RX
```

系统级复位控制器必须知道Lane与PLL的映射。单Lane异常时，若关联QPLL仍锁定，应优先恢复该Lane的数据通路，避免无条件复位共享QPLL。

## 四、`GTTXRESET/GTRXRESET`

`GTTXRESET/GTRXRESET`用于触发完整TX/RX顺序复位。

### 推荐释放条件

- 对应电源条件已满足；
- REFCLK稳定；
- 关联CPLL/QPLL已经锁定；
- 没有并发动态重配置；
- 单独PMA、PCS、CDR、Buffer复位输入保持在文档规定的非激活状态。

### 释放后的行为

```text
释放GTTXRESET
    → TX PMA开始初始化
    → TXOUTCLK可用
    → 等待TXUSERRDY
    → TX PCS/Buffer完成
    → TXRESETDONE

释放GTRXRESET
    → RX PMA/CDR/Equalizer开始初始化
    → RXOUTCLK可用
    → 等待RXUSERRDY
    → RX PCS/Buffer完成
    → RXRESETDONE
```

RX通常比TX复杂，因为接收侧还包含CDR、均衡、输入数据条件和更多恢复状态。

### 为什么不能同时操作所有局部复位

完整顺序复位状态机正在依次控制内部区域时，如果用户逻辑同时驱动`RXPMARESET`、`RXCDRRESET`、`RXPCSRESET`或`RXBUFRESET`，可能导致：

- 状态机停在中间阶段；
- `RESETDONE`不能拉高；
- 不同上电过程结果不一致；
- 局部区域刚被释放又再次进入复位。

UG576对完整RX顺序复位给出了单独复位输入的约束。其他系列应查对应UG，不能直接套用UltraScale端口集合。

## 五、`TXUSERRDY/RXUSERRDY`

`USERRDY`不是“释放复位输出”，而是用户侧送给GT复位状态机的准备完成握手。

### `TXUSERRDY`

表示：

- `TXUSRCLK/TXUSRCLK2`已经存在并稳定；
- TX用户接口逻辑可以工作；
- GT可以继续完成TX PCS等后续复位阶段。

### `RXUSERRDY`

表示：

- `RXUSRCLK/RXUSRCLK2`已经存在并稳定；
- RX用户接口逻辑可以接收数据；
- GT可以继续完成RX PCS和Buffer等后续阶段。

### 为什么`USERRDY`不能过早

PCS、Gearbox、Buffer和用户并行接口运行在User Clock域。过早置位可能引起：

- PCS在不稳定时钟下退出复位；
- `RESETDONE`不稳定或超时；
- Buffer状态异常；
- Buffer Bypass/Phase Alignment失败；
- 首批并行数据错位。

### 为什么不能简单地“先等USRCLK，再释放GTRESET”

当User Clock来自`TXOUTCLK/RXOUTCLK`时，OUTCLK可能要等PMA开始退出复位后才建立。因此正确依赖通常是：

```text
释放GTTXRESET/GTRXRESET
    → PMA开始工作
    → OUTCLK有效
    → User Clock Helper建立USRCLK
    → USERRDY置位
    → PCS继续退出复位
```

这也是Reset Helper和User Clock Helper需要配合的原因。

## 六、`TXRESETDONE/RXRESETDONE`

`TXRESETDONE/RXRESETDONE`表示对应GT内部顺序复位流程完成。

```text
PLLLOCK
    ↓
RESETDONE
    ↓
Byte/Block Alignment
    ↓
Lane/Channel Up
    ↓
Protocol Link Up
```

因此：

- `PLLLOCK=1`不能证明GT数据通路可用；
- `RESETDONE=1`不能证明接收边界已经找到；
- Alignment完成不能证明Payload或协议正确；
- Link Up仍需上层协议自己的状态判定。

### `RESETDONE`超时的优先检查

| 超时 | 优先检查 |
| --- | --- |
| `TXRESETDONE` | TX关联PLL、`TXOUTCLK/USRCLK`、`TXUSERRDY`、复位并发 |
| `RXRESETDONE` | RX关联PLL、`RXOUTCLK/USRCLK`、`RXUSERRDY`、CDR/输入条件、复位并发 |

不要在没有记录状态机卡点的情况下无限周期性重试。

## 七、PMA、PCS与RX局部复位

### `TXPMARESET/RXPMARESET`

用于PMA级局部恢复，典型场景包括：

- PMA相关动态配置；
- 某些Loopback模式进入或退出；
- RX CDR或模拟前端需要重新初始化；
- PLL保持正常，只恢复对应数据通路。

不同GT的“PMA reset是否连带PCS”及Sequential Mode行为不同，必须按目标UG确认。

### `TXPCSRESET/RXPCSRESET`

用于PCS数字部分局部恢复，适用于：

- Gearbox或编码路径重新初始化；
- 字节/块边界需要重新开始；
- 已确认PLL与PMA正常。

PCS reset不能修复REFCLK、PLL、TX Driver、RX AFE或外部信号完整性问题。

### `RXCDRRESET`

用于重新初始化CDR。适合输入信号恢复或文档规定的动态切换流程。

部分GT没有一个可直接当作“CDR已锁定”的简单可靠状态信号，Example Design可能使用等待计数或辅助FSM判断稳定。不要自行缩短文档规定的CDR等待。

### `RXDFELPMRESET`

用于RX Equalizer相关局部恢复，例如LPM/DFE配置变化。它不能代替完整RX初始化。

### `EYESCANRESET`

复位Eye Scan相关电路。它不是正常RX链路恢复的通用手段。

### `RXBUFRESET`

复位RX Elastic Buffer。使用后通常还需要：

- 丢弃当前无效数据；
- 重新执行字节/块或协议同步；
- 检查Clock Correction；
- 恢复上层协议状态。

若Buffer反复Overflow/Underflow，应排查两端频偏、Clock Correction序列和时钟架构，不能只靠周期性`RXBUFRESET`规避。

## 八、Buffer Bypass与Phase Alignment

![UG576 Figure 2-24：GTH RX Reset State Machine](assets/Xilinx-GT结构/ug576-fig2-24-rx-reset.png)

> UltraScale GTH RX顺序复位状态机，裁自UG576 v1.7.1 Figure 2-24。图中可见PMA、Equalizer、Eye Scan、PCS、Buffer及`RXUSERRDY`之间的依赖。

启用TX/RX Buffer Bypass时，`TXRESETDONE/RXRESETDONE`之后通常还要执行Delay/Phase Alignment。

常见相关信号包括：

```text
TXDLYSRESET, TXDLYSRESETDONE
RXDLYSRESET, RXDLYSRESETDONE
TXPHALIGN, TXPHALIGNDONE
RXPHALIGN, RXPHALIGNDONE
TXSYNCDONE, RXSYNCDONE
```

器件代际、自动/手动模式和Wizard配置会改变具体流程。通用依赖是：

```text
RESETDONE
    → 发起Delay/Phase Alignment
    → 等待DLYSRESETDONE/SYNCDONE
    → 允许业务数据有效
```

Buffer Bypass取消了Elastic Buffer提供的相位隔离，因此必须显式建立数据路径相位关系。推荐使用Wizard生成的Buffer Bypass Controller，不在系统FSM中复制底层脉冲序列。

## 九、上层协议复位最后释放

释放协议复位前，至少应确认：

- 关联PLL锁定；
- `TXRESETDONE/RXRESETDONE`有效；
- User Clock稳定；
- 启用Buffer Bypass时，Delay/Phase Alignment完成；
- 协议要求的其他物理层准备条件满足。

随后协议才能开始Comma/Block Alignment、Lane Bonding、Channel Initialization或Link Training。

如果协议状态机过早启动，它可能在GT数据无效时进入错误状态；GT随后恢复并不保证协议自动返回初始状态。

## 十、六种典型恢复场景

### 1. 完整上电

```text
保持全部复位
→ 等待电源/REFCLK
→ 释放并锁定PLL
→ 释放GT datapath reset
→ 建立User Clock并置位USERRDY
→ 等待RESETDONE
→ 完成Alignment
→ 释放协议
```

这是其他恢复流程的基线。

### 2. RX单通路异常

若关联PLL仍锁定、TX及其他Lane正常：

```text
保持上层RX协议复位
→ 请求RX datapath reset
→ 等待RX User Clock和RXUSERRDY条件
→ 等待RXRESETDONE
→ 重新执行RX Alignment/Training
→ 释放RX协议
```

不要默认复位共享QPLL。

### 3. 运行中PLL掉锁

```text
立即撤销相关datapath/protocol ready
→ 锁存掉锁原因和受影响Lane
→ 判断CPLL还是共享QPLL
→ 保持受影响GT复位
→ 等待REFCLK稳定
→ 重新复位并锁定PLL
→ 执行完整受影响路径初始化
```

PG182指出，部分Wizard helper在PLL掉锁后不会自动重新启动完整复位序列，系统控制器必须明确发起恢复。

### 4. 动态改速率、PLL或数据宽度

```text
停止业务并保持协议复位
→ 按文档要求进入GT/PLL复位
→ 完成DRP或配置切换
→ 等待规定稳定时间
→ 重新锁定PLL
→ 重新初始化TX/RX
→ 重做Alignment和协议训练
```

动态配置写入成功不等于新数据路径已经生效。

### 5. Loopback模式切换

先确认目标器件对该Loopback的复位要求。某些Near-End PMA切换需要重新执行RX复位。

```text
停止错误统计和业务流量
→ 保持协议/Checker复位
→ 执行文档要求的GT局部或完整复位
→ 修改LOOPBACK
→ 重新初始化受影响路径
→ 等待RESETDONE/Alignment
→ 清零Checker并开始测试
```

### 6. Buffer异常

```text
锁存Overflow/Underflow和时钟状态
→ 保持上层协议复位
→ 判断是一次性扰动还是持续频偏
→ 文档允许时执行RXBUFRESET或RX datapath reset
→ 重新同步和训练
→ 验证异常不再复发
```

若错误持续，根因通常不在“Buffer没有复位”，而可能在频偏、Clock Correction或协议配置。

## 十一、系统级复位FSM框架

### 定位

该FSM负责：

- 协调Wizard helper和上层协议；
- 管理请求、依赖、超时和有限重试；
- 保护共享QPLL资源；
- 记录错误原因。

它不应复制GT Primitive内部的复位状态机，也不应替代Wizard的User Clock和Buffer Bypass Helper。

### 概念接口

| 方向 | 概念信号 | 说明 |
| --- | --- | --- |
| 输入 | `power_good`、`refclk_stable` | 板级/GT电源和参考时钟条件 |
| 输入 | `pll_lock` | 与目标TX/RX关联的PLL状态 |
| 输入 | `tx/rx_userclk_active` | User Clock Helper给出的稳定状态 |
| 输入 | `tx/rx_reset_done` | Wizard或Primitive复位完成状态 |
| 输入 | `tx/rx_align_done` | Buffer Bypass/Phase Alignment完成 |
| 输入 | `reinit_request`、`fault_request` | 配置切换或运行期故障请求 |
| 输出 | `pll_reset_request` | 请求Wizard/PLL控制器执行复位 |
| 输出 | `tx/rx_datapath_reset_request` | 请求对应方向重新初始化 |
| 输出 | `protocol_reset` | 保持上层协议静止 |
| 输出 | `ready`、`fault_code` | 系统可用和失败原因 |

这些是概念接口，必须映射到实际Wizard端口；不要仅凭名称直接连接Primitive。

### 状态表

| 状态 | 主要动作 | 退出条件 | 典型超时 |
| --- | --- | --- | --- |
| `HOLD` | 保持PLL、datapath和协议复位 | 外部复位释放 | 无 |
| `WAIT_POWER_REFCLK` | 等待电源和REFCLK | 条件稳定 | `POWER_REFCLK_TIMEOUT` |
| `RELEASE_PLL` | 撤销PLL复位请求 | 完成规定脉宽/控制握手 | 控制器异常 |
| `WAIT_PLL_LOCK` | 保持datapath和协议复位 | `pll_lock` | `PLL_LOCK_TIMEOUT` |
| `RELEASE_GT` | 撤销datapath复位请求 | helper接受请求 | 控制器异常 |
| `WAIT_USER_CLOCK` | 等待User Clock Helper | TX/RX时钟均满足 | `USERCLK_TIMEOUT` |
| `ASSERT_USER_READY` | 允许helper推进PCS复位 | 握手完成 | `USERRDY_TIMEOUT` |
| `WAIT_RESET_DONE` | 等待TX/RX完成 | done均有效 | `RESETDONE_TIMEOUT` |
| `RUN_ALIGNMENT` | 启动/等待对齐helper | align done或未启用 | `ALIGN_TIMEOUT` |
| `RELEASE_PROTOCOL` | 释放上层协议复位 | 一个管理时钟动作 | 无 |
| `MONITOR` | 监测掉锁、Alignment和请求 | 故障或重配置 | 运行期事件 |
| `FAULT` | 保持协议复位、锁存错误 | 软件清除或有限重试 | 无 |

### 伪代码框架

```systemverilog
// 概念框架，不是可直接连接GT Primitive的完整RTL。
case (state)
  HOLD: begin
    hold_all_requests();
    if (!external_reset)
      state <= WAIT_POWER_REFCLK;
  end

  WAIT_POWER_REFCLK: begin
    protocol_reset <= 1'b1;
    if (power_good && refclk_stable)
      state <= RELEASE_PLL;
    else if (timeout)
      fail(POWER_REFCLK_TIMEOUT);
  end

  RELEASE_PLL: begin
    pll_reset_request <= 1'b0;
    state <= WAIT_PLL_LOCK;
  end

  WAIT_PLL_LOCK: begin
    if (pll_lock)
      state <= RELEASE_GT;
    else if (timeout)
      retry_or_fail(PLL_LOCK_TIMEOUT);
  end

  RELEASE_GT: begin
    tx_datapath_reset_request <= 1'b0;
    rx_datapath_reset_request <= 1'b0;
    state <= WAIT_USER_CLOCK;
  end

  WAIT_USER_CLOCK: begin
    if (tx_userclk_active && rx_userclk_active)
      state <= ASSERT_USER_READY;
    else if (timeout)
      retry_or_fail(USERCLK_TIMEOUT);
  end

  ASSERT_USER_READY: begin
    user_ready_request <= 1'b1;
    state <= WAIT_RESET_DONE;
  end

  WAIT_RESET_DONE: begin
    if (tx_reset_done && rx_reset_done)
      state <= RUN_ALIGNMENT;
    else if (timeout)
      retry_or_fail(RESETDONE_TIMEOUT);
  end

  RUN_ALIGNMENT: begin
    if (!buffer_bypass_enabled || align_done)
      state <= RELEASE_PROTOCOL;
    else if (timeout)
      retry_or_fail(ALIGN_TIMEOUT);
  end

  RELEASE_PROTOCOL: begin
    protocol_reset <= 1'b0;
    state <= MONITOR;
  end

  MONITOR: begin
    if (!pll_lock || fault_request || reinit_request) begin
      protocol_reset <= 1'b1;
      state <= select_recovery_scope();
    end
  end

  FAULT: begin
    protocol_reset <= 1'b1;
    ready <= 1'b0;
  end
endcase
```

`select_recovery_scope()`应根据故障来源决定RX datapath、TX datapath、单Channel还是共享PLL恢复；它不是固定跳回`HOLD`。

### 超时与重试原则

- 每个等待状态使用独立超时计数和错误码。
- 只允许有限次数自动重试，避免硬件永久复位振荡。
- 重试前锁存PLL、User Clock、Reset Done和共享资源状态。
- QPLL重试必须通知所有使用该QPLL的Channel。
- 软件清错不应覆盖累计失败次数和首次故障原因。

## 十二、验证场景

| 场景 | 激励 | 预期行为 |
| --- | --- | --- |
| 正常上电 | 电源、REFCLK、PLL和done按序有效 | 最终释放协议并置位`ready` |
| PLL不锁定 | `pll_lock`保持低 | 超时进入`FAULT`，协议始终复位 |
| User Clock不建立 | `userclk_active`保持低 | 不置位USERRDY，不进入RESETDONE等待 |
| RXRESETDONE超时 | TX正常、RX done保持低 | 锁存RX相关错误并有限重试 |
| 运行期PLL掉锁 | `MONITOR`中撤销`pll_lock` | 立即复位协议，按PLL范围恢复 |
| 单Lane RX故障 | QPLL保持锁定 | 仅请求目标Lane RX恢复 |
| 共享QPLL故障 | QPLL掉锁且多Lane使用 | 协调所有相关Lane，不做孤立单Lane恢复 |
| Buffer Bypass未完成 | `align_done`保持低 | 不释放协议，报告Alignment超时 |

## 十三、常见错误

- 电源或REFCLK未稳定就释放PLL reset。
- PLL未锁定就允许GT datapath继续退出复位。
- User Clock未稳定就置位`TXUSERRDY/RXUSERRDY`。
- `RESETDONE`之前启动Delay/Phase Alignment。
- Alignment完成前释放上层协议。
- 完整顺序复位期间同时操作多个局部复位。
- 单Lane故障时无条件复位共享QPLL。
- PLL掉锁后只等待它重新锁定，不重新初始化受影响数据路径。
- 用无限自动重试掩盖确定性配置或硬件问题。
- 把固定延迟、周期性复位等规避手段写成根因修复。

## FAQ

### `TXUSERRDY/RXUSERRDY`应该与`GTTXRESET/GTRXRESET`同时释放吗？

不应把它们机械地绑定在一起。GT reset释放后PMA开始建立OUTCLK；User Clock稳定后再置位`USERRDY`，允许状态机继续完成PCS等后续阶段。

### `RXRESETDONE=1`为什么仍然没有有效数据？

它只表示GT RX内部顺序复位完成。还需要CDR稳定、Byte/Block Alignment、Buffer状态和协议训练满足要求。

### 能否只用固定延迟实现所有复位？

固定延迟可用于满足文档规定的最小时间，但不能替代`GTPOWERGOOD`、`PLLLOCK`、User Clock Active、`RESETDONE`和Alignment完成状态。

### 何时应该复位QPLL？

只有关联REFCLK、QPLL配置或QPLL自身异常，或目标动态切换流程明确要求时才复位。单Channel故障且QPLL仍锁定时，优先使用Channel级恢复。

## See Also

- [[Xilinx GT结构]]：GT Quad/Channel、PMA/PCS、时钟和复位区域。
- [[Xilinx GT调试经验]]：使用Loopback、PRBS、IBERT和状态观测定位GT故障。

## Tags

`FPGA` `Xilinx` `AMD` `GT` `GTX` `GTH` `GTY` `Reset` `Initialization` `PLL` `USERRDY` `Buffer Bypass`

## References

- AMD, [7 Series FPGAs GTX/GTH Transceivers User Guide, UG476 v1.12.1](https://docs.amd.com/v/u/en-US/ug476_7Series_Transceivers), 2018-08-14.
- AMD, [UltraScale Architecture GTH Transceivers User Guide, UG576 v1.7.1](https://docs.amd.com/v/u/en-US/ug576-ultrascale-gth-transceivers), 2021-08-18.
- AMD, [UltraScale Architecture GTY Transceivers User Guide, UG578](https://docs.amd.com/v/u/en-US/ug578-ultrascale-gty-transceivers).
- AMD, [7 Series FPGAs Transceivers Wizard LogiCORE IP Product Guide, PG168](https://docs.amd.com/r/en-US/pg168-gtwizard).
- AMD, [UltraScale FPGAs Transceivers Wizard LogiCORE IP Product Guide, PG182 v1.7](https://docs.amd.com/r/en-US/pg182-gtwizard-ultrascale), 2023-05-17.
