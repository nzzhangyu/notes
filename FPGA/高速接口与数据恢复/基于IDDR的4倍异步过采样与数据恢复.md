# 基于 IDDR 的 4 倍异步过采样与数据恢复

> 该设计利用 `IDDR` 对异步串行数据进行 4 倍过采样，通过相邻样点异或检测数据边沿，再由四状态相位跟踪器选择稳定样点，并通过 bit-skip 补偿收发时钟频差。其整体思想高度吻合 Xilinx XAPP1294，状态机原理可进一步追溯到 XAPP881。

## 1. 设计目标

接收端没有使用与数据严格同步的随路时钟，而是使用本地时钟捕获异步串行数据。由于发送端与接收端之间存在初始相位差、频率偏差、时钟抖动以及温度和电压漂移，固定相位采样可能逐渐靠近数据跳变边沿。

该设计通过过采样观察数据边沿位置，并动态调整最终判决相位。它不是对多个样点求平均，而是一个数字式 Data Recovery Unit（DRU）。

## 2. 时钟与采样倍率

代码接口包含：

```vhdl
RxD   : in STD_LOGIC;
CLK4x : in STD_LOGIC;
CLK2x : in STD_LOGIC;
```

工程中 `CLK4x = 200 MHz`、`CLK2x = 100 MHz`。输入使用 `IDDR` 捕获：

```vhdl
IDDR_inst : IDDR
generic map (
    DDR_CLK_EDGE => "SAME_EDGE_PIPELINED",
    INIT_Q1      => '0',
    INIT_Q2      => '0',
    SRTYPE       => "SYNC"
)
port map (
    Q1 => Q1,
    Q2 => Q2,
    C  => CLK4x,
    CE => '1',
    D  => RxD,
    R  => '0',
    S  => '0'
);
```

`Q1` 在 `CLK4x` 上升沿采样，`Q2` 在下降沿采样，因此 200 MHz 时钟产生的有效采样率为：

$$
f_{sample}=2\times200\,\mathrm{MHz}=400\,\mathrm{MS/s}
$$

如果接口为 50 MHz DDR，即上下边沿各传输 1 bit，则线速率为：

$$
f_{bit}=2\times50\,\mathrm{MHz}=100\,\mathrm{Mbit/s}
$$

每个 bit 的采样次数为：

$$
N=\frac{400\,\mathrm{MS/s}}{100\,\mathrm{Mbit/s}}=4
$$

因此，该实现应理解为：**对 50 MHz DDR 接口进行四相位采样，对应 100 Mbit/s 线速率下每 bit 采样 4 次。**

如果实际线速率确实是 50 Mbit/s SDR，则每 bit 会得到 8 个物理采样点，这与当前 DRU 的时钟命名和输出节拍不完全吻合。

## 3. 生成 4 个连续样点

IDDR 输出经过两级寄存器：

```vhdl
process(CLK4x)
begin
    if rising_edge(CLK4x) then
        Q1F <= Q1;
        Q2F <= Q2;
        Q1R <= Q1F;
        Q2R <= Q2F;
    end if;
end process;
```

然后在 100 MHz 域中组合为：

```vhdl
RxRawData <= Q1R & Q2R & Q1F & Q2F;
```

样点顺序为：

```text
RxRawData(3)  最早
RxRawData(2)
RxRawData(1)
RxRawData(0)  最新
```

相邻样点的理论时间间隔为 2.5 ns。对于 100 Mbit/s 数据，一个 bit 持续 10 ns，因此 4 个样点覆盖一个完整 bit 周期。

## 4. 流水寄存器

原始采样数据进一步经过流水：

```vhdl
II  <= RxRawData;
ID  <= II;
IDD <= ID;
```

| 信号 | 作用 |
| --- | --- |
| `RxRawData` | IDDR 形成的当前 4 个原始样点 |
| `II` | 当前待分析采样组 |
| `ID` | 前一级历史采样组 |
| `IDD` | 用于最终数据选择的稳定采样组 |
| `I3DD` | 保存跨采样组的数据样点 |

流水既为边沿检测提供历史数据，也降低组合逻辑到输出寄存器之间的时序压力。

## 5. 相邻样点边沿检测

代码通过异或生成 `E4`：

```vhdl
E4 <= II xor (ID(0) & II(3 downto 1));
```

展开后为：

```text
E4(3) = II(3) xor ID(0)
E4(2) = II(2) xor II(3)
E4(1) = II(1) xor II(2)
E4(0) = II(0) xor II(1)
```

- `E4(n) = 0`：相邻样点电平相同。
- `E4(n) = 1`：相邻样点之间存在跳变。
- `E4(3)`：跨越前后两个 4 bit 采样组比较，保证边沿检测连续。

因此，`E4` 描述数据边沿位于 4 个候选采样相位中的哪个区间。

## 6. 四状态相位跟踪

相位状态由 `S` 表示：

```vhdl
signal S : STD_LOGIC_VECTOR(1 downto 0) := "00";
```

| 状态 `S` | 选择的数据 |
| --- | --- |
| `"00"` | `IDD(0)` |
| `"01"` | `IDD(1)` |
| `"11"` | `IDD(2)` |
| `"10"` | `IDD(3)` |

数据选择逻辑为：

```vhdl
case S is
    when "00" => DO <= I3DD & IDD(0);
    when "01" => DO <= I3DD & IDD(1);
    when "11" => DO <= I3DD & IDD(2);
    when "10" => DO <= I3DD & IDD(3);
    when others => null;
end case;
```

状态使用 Gray 顺序排列：

```text
00 → 01 → 11 → 10 → 00
```

状态机根据 `E4` 调整采样相位：

```vhdl
case S is
    when "00" =>
        if E4(0)='1' then
            S <= "10";
        elsif E4(3)='1' then
            S <= "01";
        end if;

    when "01" =>
        if E4(1)='1' then
            S <= "00";
        elsif E4(0)='1' then
            S <= "11";
        end if;

    when "11" =>
        if E4(2)='1' then
            S <= "01";
        elsif E4(1)='1' then
            S <= "10";
        end if;

    when "10" =>
        if E4(3)='1' then
            S <= "11";
        elsif E4(2)='1' then
            S <= "00";
        end if;
end case;
```

其控制思想是：检测边沿位置，判断当前采样点偏早或偏晚，向相邻采样相位移动，使最终判决点远离数据跳变。

## 7. 它不是多数表决

代码没有统计 4 个样点中 0 和 1 的数量，而是执行：

```text
相邻样点异或
→ 定位边沿
→ 调整状态 S
→ 选择指定相位样点
```

因此，准确说法是：**边沿检测驱动的动态相位选择，而不是 4 点多数表决。**

## 8. Bit Skip 频差补偿

发送端和接收端使用独立时钟时，即使标称频率相同，也会存在微小频差。随着时间积累，数据边沿会逐渐穿过 4 个采样相位。

当状态从采样窗口的一端跨到另一端，即发生 `10 → 00` 或 `00 → 10` 时，接收器需要插入或删除一个输出 bit，以避免重复或遗漏。

代码使用 `DVE` 和 `DV` 产生输出有效数量：

```vhdl
cDVE(0) <= '1'
    when S="10" and E4(3)='0' and E4(2)='1'
    else '0';

cDVE(1) <= '1'
    when S="00" and E4(3)='0' and E4(0)='1'
    else '0';

cDV(0) <= DVE(0) xnor DVE(1);
cDV(1) <= DVE(0);
```

`VO` 表示当前周期的有效数据量：

| `VO` | 当前周期有效数据量 |
| --- | ---: |
| `"00"` | 0 bit |
| `"01"` | 1 bit |
| `"10"` | 2 bit |

正常情况下每个 100 MHz 周期恢复 1 bit；发生相位跨界时短暂输出 0 或 2 bit，从而补偿异步时钟间的累计频差。

## 9. 完整数据通路

```text
异步串行输入 RxD
        │
        ▼
200 MHz IDDR 双边沿采样
        │ 400 MS/s
        ▼
Q1/Q2 流水寄存
        │
        ▼
RxRawData(3:0)：4 个连续时间样点
        │
        ▼
II、ID、IDD 流水
        │
        ├───────────────┐
        ▼               ▼
相邻样点 XOR         候选数据样点
生成 E4                 │
        │               │
        ▼               │
四状态相位跟踪器 S      │
        │               │
        └────选择相位───┘
                │
                ▼
             DO(1:0)
                │
        bit-skip 有效位控制
                │
                ▼
        Dout(1:0) + VO(1:0)
```

## 10. 与 Xilinx 官方方案的关系

该代码高度吻合 Xilinx XAPP1294 的轻量级 4 倍异步过采样 DRU：

- 使用 Artix-7 `IDDR`；
- 使用 `CLK4x`、`CLK2x`；
- 输出 4 bit raw samples；
- 使用名为 `E4` 的异或边沿阵列；
- 使用 `00/01/11/10` 四状态相位选择；
- 使用 bit skip 补偿异步频差；
- 提供 raw data 调试端口。

XAPP1294 的状态机思想又引用了更早的 XAPP881：

```text
XAPP881
高速 ISERDES/IODELAY 方案
提出 E4、四状态相位选择和 bit-skip
        │
        ▼
XAPP1294
面向 Artix-7 的轻量 IDDR 方案
        │
        ▼
当前 Data_Rec_DRU
降低时钟并缩减输出宽度的工程版本
```

XAPP1294 官方设计面向 200 Mbit/s，使用 400 MHz 捕获、200 MHz raw-data 处理、100 MHz 恢复输出，正常每周期输出 2 bit。

当前代码使用 200 MHz 捕获、100 MHz 处理和输出，正常每周期输出 1 bit。因此，当前实现很可能是将官方方案的时钟和吞吐量整体减半后的裁剪版本。由于尚未取得官方参考设计源码包进行逐行 diff，该来源判断属于高可信度工程推断，而不是已证实的逐行复制结论。

## 11. 设计边界与注意事项

### 11.1 输入需要足够的跳变密度

DRU 依赖 `E4` 检测数据边沿。若输入长时间保持全 0 或全 1，状态机无法获得新的相位误差信息，只能维持原状态。协议应保证足够的码型跳变密度，或使用定期同步字和帧头。

### 11.2 过采样不能消除亚稳态

输入 `RxD` 对本地时钟异步，采样点仍可能落在数据边沿附近。过采样和流水寄存器能够选择更稳定的样点、限制亚稳态传播风险，但不能证明亚稳态绝对不会发生。

### 11.3 XAPP881 的高速指标不能直接套用

XAPP881 使用两套 `ISERDESE1`、`IODELAYE1`、MMCM 多相位时钟和 BUFIO/BUFG 相位校准。当前代码没有这些结构，因此 XAPP881 给出的接收眼图和抖动容限不能直接作为当前设计指标。

### 11.4 `after 0.1 ns` 不是硬件延迟单元

代码中的：

```vhdl
signal <= value after 0.1 ns;
```

主要用于仿真中表现传播延迟，不能理解为综合后硬件中精确存在 0.1 ns 延迟。实际延迟由器件、布局布线和时序约束决定。

## 12. 验证建议

1. 将输入数据相位在 0～1 UI 内连续扫描。
2. 分别设置接收时钟比发送时钟快和慢。
3. 注入随机抖动及占空比失真。
4. 检查 `E4` 是否正确指示边沿位置。
5. 检查 `S` 是否只在相邻相位间移动。
6. 检查 `VO="00"` 和 `VO="10"` 时是否丢失或重复数据。
7. 测试长连 0、长连 1 和低跳变密度码型。
8. 对比恢复数据与发送端原始 bit 流。
9. 上板测试时进行长时间误码率统计。

## 13. 总结

该模块的核心思想为：

```text
用 IDDR 取得 4 个连续样点
→ 用异或定位数据边沿
→ 用四状态机跟踪最佳采样相位
→ 从候选样点中选择稳定数据
→ 用 0/1/2 bit 输出补偿时钟频差
```

它是一个轻量级异步数据恢复器，而不是普通同步器或多数表决器。代码与 Xilinx XAPP1294 官方参考设计高度一致，属于 XAPP881/XAPP1294 系列 4 倍异步过采样 DRU 思想的工程化裁剪版本。

## 14. Verilog-2001 实现

完整转换文件：

- [Data_Rec_DRU.v](rtl/Data_Rec_DRU.v)

该文件以本文分析的完整 VHDL 源码为基准，保留 IDDR、四样本流水、`E4`、四状态 FSM、bit skip 以及 `Dout/VO/RawData_o` 的周期级行为。

### 14.1 端口

| 端口 | 方向 | 宽度 | 时钟域/含义 |
| --- | --- | ---: | --- |
| `RxD` | input | 1 | 异步串行输入 |
| `CLK4x` | input | 1 | IDDR 和高速采样流水时钟 |
| `CLK2x` | input | 1 | raw data、E4、FSM 和输出时钟 |
| `rst` | input | 1 | 新增的高有效同步复位 |
| `Dout` | output | 2 | 恢复的数据输出 |
| `VO` | output | 2 | 当前周期有效数据位数编码 |
| `RawData_o` | output | 4 | 原始四样本调试输出，bit 3 最早、bit 0 最新 |

原 VHDL 没有复位端口，而是依靠信号声明初值。Verilog 版本有意增加 `rst`：

- `CLK4x` 域寄存器在 `CLK4x` 上升沿同步复位；
- `CLK2x` 域寄存器和输出在 `CLK2x` 上升沿同步复位；
- 7 Series `IDDR` 保持 `SRTYPE="SYNC"`，其 `R` 端连接 `rst`；
- 调用方必须保证 `rst` 分别满足两个时钟域的同步时序要求。

### 14.2 主要语法对应

| VHDL | Verilog-2001 |
| --- | --- |
| `generic map` | 原语参数 `#(...)` |
| `port map` | 命名端口连接 `(...)` |
| `Q1R & Q2R & Q1F & Q2F` | `{Q1R, Q2R, Q1F, Q2F}` |
| `II xor ID(0)&II(3 downto 1)` | `II ^ {ID[0], II[3:1]}` |
| `DVE(0) xnor DVE(1)` | `~(DVE[0] ^ DVE[1])` |
| 时钟进程中的 `<=` | `always @(posedge ...)` 中的非阻塞赋值 `<=` |
| `when others => null` | `default` 分支保持寄存器原值 |

原代码中的 `after 0.1 ns` 只用于表现仿真传播延迟，综合时不会生成精确的 0.1 ns 硬件延迟。Verilog 版本将其全部移除，不使用 `#delay`；这不会改变以时钟周期为尺度的综合功能。

### 14.3 器件原语

当前活动实例保持为 7 Series `IDDR`。文件内只保留 UltraScale+ `IDDRE1` 的迁移提示，不加入自动器件选择逻辑；迁移时应按目标器件文档重新核对 `C/CB` 时钟连接和原语属性。

## References

- [AMD/Xilinx XAPP1294 — Lightweight and Scalable 4x Oversampling Asynchronous Data Recovery Unit](https://docs.amd.com/v/u/en-US/xapp1294-4x-oversampling-async-dru)
- [AMD/Xilinx XAPP881 — Virtex-6 FPGA LVDS 4X Asynchronous Oversampling at 1.25 Gb/s](https://docs.amd.com/v/u/en-US/xapp881_V6_4X_Asynch_OverSampling)
- 工程源码：`Data_Rec_DRU.vhd`

## See Also

- [[XAPP1294 基于IDDR的4倍异步过采样与DRU]]：XAPP1294 原文机制专篇；本笔记则保留具体工程的时钟缩放和 RTL 解释。
- [[XAPP881 Virtex-6 4倍异步过采样与DRU]]：XAPP881 原始 Virtex-6 高速方案，使用 `ISERDESE1`、`IODELAYE1`、MMCM 和 BUFIO/BUFG 相位校准；不要与本笔记的 IDDR/XAPP1294 轻量实现直接混用。

## Tags

`FPGA` `LVDS` `Oversampling` `DRU` `CDR` `IDDR` `XAPP1294` `XAPP881` `Artix-7`
