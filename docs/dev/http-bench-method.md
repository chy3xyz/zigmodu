# HTTP 基准方法与 h1/h2 现状（含一次 Debug 误判的复盘）

> 状态：**方法已落地，结论已修正**。上一版这篇文档把 "h2c 每请求 ~4 ms" 记成框架缺陷；
> 复核后是 **Debug 构建 + 逐帧 debug 日志 + 弱客户端** 三者叠加的测量假象。ReleaseFast
> 下 h2 反而比 h1 快。这里保留过程和数字，避免下一个人再被同一组数字误导。

## 一条命令

```bash
bash scripts/bench-e2e.sh --requests 2000 --json-out e2e.jsonl
# 默认 ReleaseFast 构建 examples/http-stress-test；--debug 才用 Debug（仅调试用，别读数字）
```

脚本自己起停服务器，输出 h1 keep-alive 与 h2c（prior knowledge）在**同一进程、同一 handler**
上的延迟与吞吐，JSON 带 commit/宿主，可按 `kind: "http-e2e"` 累积。

## 数字（macOS aarch64，回环，ReleaseFast，同一服务器）

客户端：`h2load`（1.70）+ `wrk`，不是 Python——Python 的 h2 客户端在单连接上约 13k req/s
就成瓶颈，会把服务器能力读低一个数量级。

| 场景 | 吞吐 | 请求延迟中位数 |
|---|---:|---:|
| h1，16 连接（`h2load --h1`） | 67.3k req/s | **225 µs** |
| h2c，16 连接 × 1 流 | 60.8k req/s | **208 µs** |
| h2c，16 连接 × 16 流 | **125–130k req/s** | 1.44 ms |
| h1，64 连接（`wrk`，对照） | 63–69k req/s | — |

结论与常见直觉相反但合理：**同并发下单请求 h2 略快于 h1**；h2 的吞吐优势来自多路复用，
代价是高并发下排队延迟上升。h1 在 64/128/256/512 连接下都在 60–69k 平台期，属连接级串行 +
每请求 syscall 成本的正常形状。

## 上一版为什么错：Debug 构建

同一份代码、同一个 Python 客户端：

| 构建 | h1 keep-alive | h2c 多路复用 |
|---|---:|---:|
| Debug | 10.2k req/s | **275 req/s**（≈3.6 ms/请求） |
| ReleaseFast | 36.4k req/s | **13.5k req/s** |

Debug 下 h2 路径每帧都有边界检查、无内联，且 `std.log` 默认级别是 `.debug`——帧处理里的
`std.log.debug` 全部生效并格式化字符串。**任何 HTTP 数字都必须标注构建模式**；这也是
`bench-e2e.sh` 现在默认 ReleaseFast 的原因。`bench-results.json` 的微基准本来就是
ReleaseFast（`scripts/check-bench.sh`），只有端到端这条之前漏了。

## 本轮做的优化：SO_SNDTIMEO 每会话一次，而不是每写一次

`Http2Server.ConnWriter.flush` 原先走 `sockread.writeFullBounded`，每次写做
`setsockopt(SO_SNDTIMEO)` 设值 + 清零，**每个响应 2 次额外 syscall**。h2 会话里这个 writer
是唯一的写者、socket 随会话关闭，没有 `writeFullBounded` 注释里担心的"别的写者被遗留超时
误伤"的场景，所以在 `ConnWriter.init` 里 arm 一次，写路径改用 `writeFull`。

实测（`h2load -n 200000 -c 16 -m 16`，交替 3 轮）：

| 版本 | 吞吐 |
|---|---:|
| 每写 arm/clear | 103–109k req/s |
| 每会话 arm 一次 | **125–130k req/s** |

+18–20%，服务器 CPU 约 217% → 196%（同 1M 请求负载）。42 条 h2 测试（含写预算、
"失败后空 flush 不是 no-op"）全绿；单测口径不变。

第二项：**每帧一次 `allocator.alloc/free` 改成会话内复用缓冲**（`readFrameInto`，按需
增长，不预分配到 `max_frame_size`；HEADERS 就地解码、DATA 由 `appendData` 拷贝，没有
handler 保留帧切片）。每请求省 2–4 次分配；交替复测 118–124k → 125–133k（宿主噪声较大，
取趋势），无回退。

## 候选与结论

1. **h1 的写路径省 `setsockopt`：试过，无收益，已回退。** 按 h2 的方案做了连接级
   `send_armed` 状态 + `BoundedWriter.initArmed`（流式/错误路径后重新 arm），全量测试
   绿；`wrk -c64` 交替 4 轮：旧 72.4–73.4k、新 72.4–75.3k——**差异在噪声内**。h1 的瓶颈
   不在写路径的两个 syscall，更可能在每请求的 `poll` + `read`（`StreamReader.readInto`
   的 slowloris deadline）与调度唤醒。改动已回退，避免为一个未证实的收益维护
   "socket 是否 armed" 的跨函数不变量。
2. **h1 读路径的 `poll` + `read`** —— 语义与取舍见下一节；决定是暂不改。
3. **高并发排队延迟：已核实是 Little's law，不是调度缺陷。** 实测（h2load，16 连接 ×
   16 流）：125k req/s 时在飞 256 个请求，256 / 125000 = **2.05 ms**，实测中位 1.4–1.8 ms；
   Zig 客户端 66k req/s 时 256 / 66000 = **3.88 ms**，实测 3.86 ms。两者都落在
   在飞数 / 吞吐 上，说明延迟是并发深度换来的排队，不是流唤醒顺序的问题。要降延迟只有
   两条路：提高吞吐，或减少在飞数。
4. **端到端噪声：已用"每连接预热 + 多轮取中位"处理**（见下一节）。

## Zig 客户端与回归门禁（不依赖 nghttp2）

`src/bench_http.zig` 是一个零依赖的压测客户端：

```bash
zig build bench-http -- --proto h2c --conns 16 --streams 16 --requests 100000
zig build bench-http -- --proto h1  --conns 64 --requests 100000
```

它用框架自己的 `http.Http2` 原语编码帧（h2c prior knowledge），每连接一个线程、原始
`send`/`read`，响应按帧解析。**它是生成器不是独立实现**：协议一致性仍用 `h2load`/curl，
吞吐上限也用 h2load（Zig 客户端逐帧两次 `read`，单机约 65–75k req/s 就客户端饱和；
h2load 同条件 125k）。拿来跑门禁足够，因为门禁比的是同一客户端的历史中位数。

```bash
# 3 轮取中位，和本机基线比，低于 0.6x 才失败；--update 录制基线
bash scripts/check-bench-e2e.sh --rounds 3
bash scripts/check-bench-e2e.sh --rounds 3 --update
```

- 基线按 `os-arch` 分键（`scripts/bench-e2e-baseline.json`）：绝对 req/s 不跨宿主；
  没有本机条目时打印 "no baseline" 并以 0 退出，录制一次即可。
- 每轮客户端自己做 `--warmup 20`，计时从连接就绪后才开始。
- 脚本同时打印 Little's law 的预期 p50（在飞数 / 吞吐），方便一眼看出"延迟变高"是
  排队还是服务变慢。

## h1 读路径为什么没改

`StreamReader.readInto` 现在是 `poll(remaining)` + `read`：每次读 2 个 syscall，但
`poll` 带的是**绝对剩余预算**，一个每 (timeout-1) ms 吐一个字节的 slowloris 会在绝对
deadline 被切断。改成 `SO_RCVTIMEO` + 直接 `read` 只省一次 syscall，但超时语义变成
**每次读**计时：同样的慢速 peer 最多能耗到 ~2× 预算（读前检查 + 单次读超时），要恢复
绝对语义就得每次读前 `setsockopt(min(remaining, T))`——又把省下的 syscall 花回去了。
考虑到 h1 写路径的 A/B（同样省 2 次 syscall）吞吐差异在噪声内，**这项暂不做**；如果
将来要做，形态应是 `Config` 上显式的 `read_deadline_mode = .absolute_poll | .socket_timeout`，
默认保持 `absolute_poll`。

## 验收判据

同宿主、同客户端、同并发下比较**比值**，不看绝对 req/s：

- 同并发（16 连接 × 1 流）h2 中位延迟 ≤ h1 中位延迟的 1.2 倍；
- h2 多路复用吞吐 ≥ h1 同连接数的 1.5 倍；
- 任何"性能回归"结论必须附构建模式、客户端、连接数/流数三要素。
