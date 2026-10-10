# 评审意见 · PR #3 `fix(sqlx): ConnPool acquire 的 deadline 改用单调时钟而非切片计数`

**结论：修复正确，建议合并；建议把新增测试换成一段「为什么没有测试」的注释。**

---

## 一、修复本身：✅ 正确

`sqlx.zig` 的 `acquire` 从「切片计数」改成「真实 deadline」，与既有的
`src/pool/Pool.zig` 修复**同构**——那边 `Pool.acquire` 早就把同一种假账修掉，
注释里还留着病历：

> *assumed* 10 ms per wake-up, so an exhausted pool … budget that had never elapsed

两条断言我都核实过：

- `sqlx.zig` 修复前的 `waited_ms += 50` 确实存在，且每轮**无条件**累加
- `Pool.zig` 的那段修复记录确实存在，PR 的引用准确

**缺陷是真实的**：切片提前返回（spurious wakeup）时预算被高估，
`acquire` 会在真实时间尚有剩余时提前放弃。

CI 也全绿（10 成功 / 0 失败，含 postgres + mysql + Redis/NATS/Kafka 三平台腿）。

---

## 二、测试：⚠️ 抓不住它声称要抓的 bug

我做了变异验证：把修复改回原样（恢复 `waited_ms += 50`），
跑全量 → **2320/2383 passed，零失败**。那个新测试**没有变红**。

### 为什么必然抓不住（不是调参问题）

关键在于循环条件在**切片开头**求值，所以：

| | 实耗 |
|---|---|
| 修复前（切片计数） | `ceil(max_wait_ms / 50) × 50` |
| 修复后（真实时间） | **`[max_wait_ms, max_wait_ms + 50)`** |

**这两个区间对任何 `max_wait_ms` 都重叠。** 切片真睡满时每轮都是 +50，
两条路径同步推进 —— 所以任何时序断言都同时满足两边。

而 PR 选的 `max_wait_ms = 120` 恰好是最坏取值：它是50 的整数倍，两条路径
都落在 100–150ms，断言 `elapsed >= 100` 通过。

> 实测校准：`max_wait_ms = 130` 时修复版实际耗时 **156ms**（不是我最初推算的 130ms），
> 因为第三个切片在 t=100ms 进入后必须睡满。这就是上表中区间的由来。

### 也试过、且不可行的两条路

1. **多 waiter 并发制造提前唤醒**——`release()` 只signal 队首 waiter
   （`orderedRemove(0)`），其余 waiter 各等自己的 cond，**不会被唤醒**。
   唯一真正的提前返回来源是 **spurious wakeup**，不可控、不可复现。
   池级那个 `self.cond.signal`（`:4746`）全仓**无任何 wait**，不参与唤醒。
2. **多线程调用 `acquire`**——实测 `signal ABRT`：`std.testing.io` 的语义下
   不安全，需要注入 IO 或改签名，超出本 PR 范围。

---

## 三、建议的改动：把测试换成注释

这个 bug 在当前架构下**写不出确定性回归测试**。留一个无效测试比没有测试更危险，
因为它给人虚假的安全感。所以建议删掉那个测试，在修复处留一段说明：

```zig
// Deadline is measured on the monotonic clock, not by counting slices. A
// counting loop assumed each iteration consumed a full 50ms, but a slice can
// return early (spurious wakeup), which made the budget over-count and
// abandon an acquire that still had time left. Same fix as
// `pool.Pool.acquire`.
//
// **No regression test, and that is deliberate.** When every slice sleeps its
// full 50ms, "slices counted" and "time elapsed" advance in lockstep — the
// loop condition is evaluated at each slice *head*, so a counter and a clock
// produce `ceil(max_wait_ms/50)*50` and `[max_wait_ms, max_wait_ms+50)`
// respectively, and those ranges **overlap for every value of
// `max_wait_ms`**. Any timing assertion therefore passes against both
// implementations. The two diverge only when a slice returns early, which
// here happens solely via a spurious wakeup — not reproducible from a test.
//
// To make this testable the slice budget would have to become injectable
// (the deterministic `Clock` used by `src/runtime/scheduler.zig` is the
// obvious route), which is a larger change than this fix.
```

---

## 四、同意的部分

- 「不引入 API 变更」—— 确认：`acquire` 的签名与返回契约都没动
- 「与 `Pool.acquire` 已验证的写法一致」—— 确认，且这正是它值得合的原因：
  **同一个坑，一个已修、一个漏了**，这类「同源缺陷的第二处」自己最难发现
- 破坏性：否 —— 同意

---

## 五、一句话

修复是对的，请合；**但请把那个抓不住 bug 的测试换掉** —— 用注释记录「为什么
写不出来」，比留一个假绿灯更有价值。
