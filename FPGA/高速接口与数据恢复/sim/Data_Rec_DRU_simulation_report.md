# Data_Rec_DRU 功能仿真结果

> 当前 DUT 和自检式 testbench 已通过 Vivado 2019.1 编译与展开；XSim 运行被本机损坏的 Tcl 运行库阻断，因此尚未产生 BER 和场景 PASS/FAIL 结论。

## 仿真对象

- DUT：`../rtl/Data_Rec_DRU.v`
- Testbench：`tb_Data_Rec_DRU.sv`
- 目标系列：AMD/Xilinx 7 Series
- 计划器件：`xc7a325tffg900-2`
- 仿真器：Vivado Simulator 2019.1
- 原语模型：`unisims_ver.IDDR`

DUT 根据用户提供的 `pasted-text.txt` 恢复。忽略换行符和文件尾空行后，工作区 DUT 与附件文本完全一致。

## 测试参数

| 项目 | 设置 |
| --- | --- |
| `CLK4x` | 400 MHz |
| `CLK2x` | 200 MHz |
| 标称数据速率 | 200 Mb/s |
| 频差场景 | 202 Mb/s、198 Mb/s |
| 初始相位 | 一个 UI 内 8 点扫描 |
| 数据长度 | 每场景 10,000 bit |
| 数据码型 | 256-bit 训练序列、PRBS7、32-bit 连 0、32-bit 连 1 |

## 自检内容

- 根据 `VO=00/01/10` 提取 0/1/2 个有效 bit。
- 自动搜索发送流与恢复流的流水偏移并计算 BER。
- 检查 `Dout`、`VO`、`RawData_o`、`EQ`、`E4` 和 `bit_skip_event` 中的 `X/Z`。
- 检查 `VO` 合法值。
- 检查 positive/negative bit skip 不会同时发生。
- 检查 `EQ` 状态转移与 RTL 定义一致。
- 统计恢复位数、两类 bit skip 次数、断言错误和场景结果。

## 已完成验证

| 阶段 | 结果 | 证据 |
| --- | --- | --- |
| SystemVerilog testbench 编译 | 通过 | `xvlog --sv tb_Data_Rec_DRU.sv` |
| Verilog DUT 编译 | 通过 | `xvlog Data_Rec_DRU.v` |
| IDDR 原语解析 | 通过 | `unisims_ver.IDDR`，`SAME_EDGE_PIPELINED` |
| 静态展开 | 通过 | `xelab tb_Data_Rec_DRU glbl -L unisims_ver` |
| 时间精度 | 1 ps | Xelab 报告 |

## 阻塞项

XSim 启动时读取：

```text
D:\Xilinx\Vivado\2019.1\tps\tcl\tcl8.5\init.tcl
```

该文件开头包含 `Esafenet` 二进制标记，不是合法 Tcl 文本。XSim 因此在运行测试前退出，错误属于 Vivado 安装环境损坏，不是 DUT 或 testbench 编译错误。

在修复或重装 Vivado Tcl 8.5 运行库前，以下结论均为待验证：

- 10 个场景的 BER；
- 正负频差下的 bit-skip 方向；
- `Dout[1:0]` 在双 bit 输出周期内的时间顺序；
- 所有运行时断言。

## 时序结论边界

本测试是 RTL 功能仿真。即使全部场景通过，也不能证明 `xc7a325tffg900-2` 上的 setup/hold、I/O 时序、时钟偏斜或布局布线时序满足要求。物理时序仍需综合 STA 或实现后时序分析。
