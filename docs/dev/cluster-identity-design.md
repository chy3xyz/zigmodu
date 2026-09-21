# 总线的节点身份绑定 —— 设计（未实现）

> 状态：**设计草案，未实现**。承接 `docs/dev/cluster-auth-design.md` §14 里那条
> "`source_node` 仍未被绑定 —— 记为 open，没有关"。
> 所有事实带 `文件:行`；推测处显式标注"未验证"。

## 0. 结论

§14 那套 `identityKey` **没有绑定身份**，而且**也不可能**绑定：它的 key 是
`HMAC(cluster_secret, claim)`（`DistributedEventBus.zig:384`），**任何持有 `cluster_secret` 的人
都能推导出任何节点的 key**。所以它相对"直接 MAC 整段 json"没有额外安全性 ——
`cluster-auth-design.md` §14 自己也承认了这一点。

要真的绑定，只有一条路：**每个节点一份自己的凭证**，并在连接建立时**握手**把"这条连接是谁"
钉住。这是一次**新协议步骤**，不是现有帧的微调。

## 1. 现状与它挡不住什么（逐条可核对）

| 事实 | 位置 |
|---|---|
| key = `HMAC(cluster_secret, claim)` —— 共享秘密的纯函数 | `:384` |
| 收方为了推 key，必须**先读未验证字节里的 `claim`** | `:455` `openEventFrame` |
| 帧上没有任何"谁"的证明，只有自述 + 一个可被有秘密者伪造的 MAC | 文件头 `:18-19` |
| 地址簿不能代替身份：`self.nodes` 存的是**我们拨出去**的 `host:监听端口`，入站对端是 `dialer_ip:临时端口` | `:93`，§14 |

**它能挡的**：没有 secret 的陌生人（他连 MAC 都算不出来）。
**它不能挡的**：**集群内部**任何一个节点冒充另一个节点 —— 因为秘密是共享的。

所以今天 `source_node` 的可信度上限是"**来自某个持有 secret 的主机**"，不是"**来自 node-b**"。

## 2. 威胁模型

- 攻击者 A：无 secret 的外部主机（§14 已挡）。
- 攻击者 B：**持有 secret 的一个集群成员**，或拿到过 secret 的人。**本设计针对 B。**
- 不在范围内：能读进程内存 / 能改二进制的本地攻击者；流量机密性（帧仍是明文，见 §9）。

**B 今天是完全自由的**：拿 `cluster_secret` 就能给任意 `source` 铸帧、也能推导任何节点的 key。
本设计要求 B 只持有**自己那一份** key，从而只能以自己出现。

## 3. 设计：每节点凭证 + 挑战-应答握手

### 3.1 凭证

每个节点持有一份**自己的** 32 字节 key，并且**知道对端的 key**（集群是静态成员表，与
`BootstrapConfig.peers` 同一量级的信息）。

```zig
pub fn setOwnKey(self: *Self, key: [32]u8) void;                       // 我这个节点出示什么
pub fn setPeerKey(self: *Self, peer_id: []const u8, key: [32]u8) void; // 我怎么验它
```

密钥来源与应用侧其余秘密一致：**应用自己从 `SecretsManager` 取再填进来**，框架不新造一条密钥通道
（同 `cluster_secret` 的既有约定，`:1067`）。

### 3.2 握手（连接建立后，任何事件帧之前）

**接收方先发挑战**，这样握手本身不可重放（否则把一段捕获的握手字节重放给同一个接收方，
就能"成为"那个节点）：

```text
① receiver → dialer   [len][challenge: 16 bytes]        challenge 每条连接新取一次
② dialer   → receiver [len][claim_id][mac: 32]          mac = HMAC(own_key, claim_id || challenge)
③ receiver：查 peer_keys[claim_id]；缺 → 关闭（debug 日志）
            常时比较 mac；失败 → 关闭
            通过 ⇒ 这条连接**绑定** claim_id，且 challenge 作废（单次使用）
```

`challenge` 用 `std.Io.randomSecure` 取（不是时间戳 —— 同一进程低熵种子的教训已经吃过一次）。

**双向认证（互证）**：② 里 dialer 顺带带上自己的 challenge，③ 接收方回
`HMAC(own_key, own_node_id || dialer_challenge)`。**建议做**，因为拨号方同样会信任这条连接的
对端；只做单向的话，拨号方对"对面是不是我拨的那个节点"毫无保证。

### 3.3 事件帧改成用**绑定后的** key

```text
绑定成功之后，该连接上：
  出站： mac = HMAC(peer_key(对端 id), json)
  入站： mac = HMAC(peer_key(bound_id), json)，并且 event.source_node 必须 == bound_id
```

于是：

- **`identityKey` 删除** —— key 不再从 `claim` 推，`claim` 改由握手负责。
- **`source_node` 第一次成为可验证的事实**：不是自述，而是"这条连接在握手时证明过自己是它"。
- 帧里仍然带 `"source"`（WAL 重放、本地投递都要它），但它现在是**被校验的**，不是被信任的。

### 3.4 与现有重放防护的关系

`seq` 那套（`:376 nextSeq` / `:609 acceptSeq` / `:115 peer_seqs`）**保留**：它挡的是**事件帧**
的跨连接重放，握手挡的是**握手**的重放。两者互补，`seq` 的既有局限（重启回退、`forgetPeerSeq`
要手动）不变，仍记在 §14。

## 4. 为什么必须是握手，而不是再加一个字段

- **加字段解决不了**：任何"自述 + 用共享秘密 MAC"的形状，持秘密者都能为任意自述铸 MAC。
  问题不在字段的多少，在**秘密是不是共享的**。
- **每连接绑定**（而不是每帧自述）是唯一能省掉"每帧证明身份"的形状：握手一次，之后靠连接。
  这也是 TLS 客户端证书 / SSH 的做法 —— 不是我们的发明。
- **挑战必须是接收方给的**：否则重放。

## 5. fail-closed 与配置面

沿用 `ClusterBootstrap` 那套"拒绝 + 显式承认"的惯用法（`cluster-auth-design.md` §3.5）：

| 场景 | 行为 |
|---|---|
| 配了 `own_key`，拨号到**没有** `peer_key` 的对端 | `connectToNode` **拒绝**（`error.PeerKeyMissing`） |
| 收到握手，`claim_id` 不在 `peer_keys` 里 | 关闭连接（debug 日志），**不回落**到旧行为 |
| 握手 MAC 不对 / 重放 | 关闭连接 |
| 绑定后帧的 `source` ≠ 绑定 id | 关闭连接 |
| **完全没配任何 key** | 走既有的裸帧路径（单节点/开发），`start()` 打既有的 warn（`:166`） |
| 配了 key 但握手里出现裸帧 | 拒绝 —— **不允许在同一端口上混合** |

最后一条是关键：**不能有"降级到不认证"的路径**，否则整条修复作废（与 §5 的硬切同一理由）。

## 6. 爆炸半径：硬切

握手是**新的一步**，帧的 MAC key 也变了。混合版本**两个方向都听不懂**：

- 新节点对旧节点发的第一帧 → 期望是 challenge，收到的是事件帧 → 关；
- 旧节点对新节点发的 challenge → 期望是 json，解析失败 → 进 DLQ（**不是**静默）。

**建议：不协商，硬切**，失败形态是"总线连不上"，而不是"看起来正常但不设防"。
与 §10 的 `@id`、§14 的帧格式同一类处理，`docs/UPGRADING.md` 的 v0.32.0 段要补一条。

**额外代价（如实记）**：每连接多一次往返（challenge → response）。总线连接是长生命周期、
事件速率远低于 Raft 心跳，这个代价可以忽略；但**连接建立延迟增加一个 RTT**，对
"每事件一条连接"的用法（如果存在）会是显著变化。**未验证**：树内是否有这种用法 —— 实现时查。

## 7. 实现前的红证据清单（先写红，再动代码）

| # | 用例 | 期望 | 变异（红的样子） |
|---|---|---|---|
| 1 | 握手 MAC 用 **node-a 的 key** 算，却声称 `node-b` | 关闭 | 去掉 key 查表 → 通过（红） |
| 2 | 重放**同一条**握手（同一个 challenge） | 第二次关闭 | challenge 复用不去除 → 通过（红） |
| 3 | 绑定 `node-a` 后，发 `source = "node-b"` 的帧 | 关闭 | 不校验 `source` → 投递（红）——**这条是身份绑定的判据** |
| 4 | 没握手就发事件帧 | 关闭 | 不检查绑定状态 → 投递（红） |
| 5 | `connectToNode` 到没有 `peer_key` 的 id | `error.PeerKeyMissing` | 去掉门禁 → 拨出去（红） |
| 6 | 正对照：双向握手都对 | 帧正常收发 | — |
| 7 | 双向认证失败（接收方 MAC 不对） | 拨号方拒绝该连接 | 不验互证 → 接受（红） |

**#3 是这条设计的核心判据** —— 它证明"持自己 key 的节点不能再以别人出现"，而今天的代码
（以及 §14 的 `identityKey`）在持有 `cluster_secret` 时**会通过**。

## 8. 分阶段

| 阶段 | 内容 | 判据 |
|---|---|---|
| 1 | 凭证表 + `setOwnKey` / `setPeerKey` | 单纯的存取 + 测试 |
| 2 | challenge-response 握手（接收方 + 拨号方），双向 | 红证据 1、2、6、7 |
| 3 | 绑定连接；`source` 必须等于绑定 id；**删除 `identityKey`** | 红证据 3、4 |
| 4 | 接线 `connectToNode` / `start()` 的 fail-closed；`ClusterBootstrap` 传递 | 红证据 5 |
| 5 | 文档：§14 的指针、`DISTRIBUTED.md`、`UPGRADING.md`、CHANGELOG | 门禁 |

阶段 2 是唯一有设计余量的地方（报文编码形状）；3–4 基本是接线。

## 9. 明确不做

- **不做加密**：帧仍是明文。握手给的是**身份**，不是**机密性**。要机密性走 TLS/边车
  （与 `cluster-auth-design.md` §5 同一条）。
- **不做密钥轮换 / 撤销**：静态成员表 + 静态 key，与集群既有的静态 `peers` 一致。要轮换是另一件事。
- **不动 Raft 侧** —— 但要说清楚：**Raft 的 L1 有同一个性质**（共享 PSK 的 `ClusterAuth` 不绑定身份），
  Raft 靠 **L2 的成员校验**兜住"自述 id 必须是成员"，而**那个 id 的可信度同样只有"持有 secret 的主机"**。
  所以本设计只是总线那一半；Raft 那一半是**同形的一件事**，另开一轮。
- **不修 `ConcurrentError` 的用例缺口**（`testing.io` 的 `concurrent_limit` 是 unlimited，树内构造不出来）。
- 不动 `serializeEvent` / 重放那套（§14 已完成）。

## 10. 需要定的三件事

1. **握手形状**：接收方先发 challenge（本设计，挡握手重放）还是拨号方先发、接收方回 nonce？
   我建议前者 —— 重放防护更直接。
2. **双向认证**：现在就做互证，还是先只做接收方验拨号方？（我建议现在就做：拨号方同样在信任对端。）
3. **凭证粒度**：`setPeerKey(id, key)` 逐对端配置（本设计），还是一个"节点 id → key"的配置文件由
   框架读？我建议前者 —— 与 `secrets` 的既有约定一致，框架不新造密钥通道。
