# Xilinx 过采样 CDR/DRU 文档索引

> 小记：高速 SelectIO 四倍异步过采样以 XAPP523 为主笔记；通用数字DRU优先阅读XAPP1240，突发模式再看XAPP1252和XAPP1277。

## 文档一览

| 文档 | 日期/版本 | 主要内容 | 阅读建议 |
| --- | --- | --- | --- |
| [XAPP523：LVDS 4x Asynchronous Oversampling Using 7 Series](https://docs.amd.com/v/u/en-US/xapp523-lvds-4x-asynchronous-oversampling) | v1.1，2017-05-17 | 7 Series LVDS、SelectIO、4倍异步过采样 | **高速SelectIO主方案**，包含8样本、E4、FSM和bit skip |
| [XAPP1240：Clock and Data Recovery Unit based on Deserialized Oversampled Data](https://docs.amd.com/r/en-US/xapp1240-k7-us-clk-data-recovery/Summary) | v3.1，2022-11-04 | NIDRU、分数倍过采样、动态参数、并行输出和在线水平眼图扫描 | **最推荐继续阅读**，是更通用的数字过采样 CDR |
| [XAPP1252：Burst-Mode Clock Data Recovery](https://docs.amd.com/v/u/en-US/xapp1252-burst-clk-data-recovery) | v1.3，2019-04-12 | GTH/GTY 突发模式 CDR、快速且有界的锁定时间 | 适合需要 burst-mode 快速锁定的高速链路 |
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
