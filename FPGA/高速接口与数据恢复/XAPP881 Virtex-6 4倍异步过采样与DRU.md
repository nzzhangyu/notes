# XAPP881：Virtex-6 4 倍异步过采样与 DRU（已废弃）

> 本笔记已废弃。知识库中的高速 SelectIO 4倍异步过采样主方案已更新为7 Series XAPP523。

请阅读：

- [[XAPP523 7系列LVDS 4倍异步过采样与DRU]]

替代原因：

- XAPP523使用7 Series `ISERDESE2`、`IODELAYE2`和`MMCME2_ADV`；
- DRU的8样本重映射、E4、四状态FSM和bit skip原理保持一致；
- 新笔记统一采用7 Series硬件结构、时钟校准和约束，不再维护Virtex-6原语实现。

原XAPP881图片保留在`assets/xapp881/`，仅用于历史回溯。当前笔记和新设计不应继续引用其中的Virtex-6硬件结构。

## References

- Xilinx, *Virtex-6 FPGA LVDS 4X Asynchronous Oversampling at 1.25 Gb/s*, XAPP881 v1.1, 2014-09-24。

## Tags

`FPGA` `XAPP881` `Deprecated`
