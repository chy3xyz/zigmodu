# 总线的节点身份绑定 —— 设计（**已实现**）

> 状态：**已实现**（2026-09-21）。落地记录见本文末 **§11**；本文其余部分是设计原文，
> 实现期与它相左的地方在 §11 里逐条点名（其中一处是 §3.3 的 MAC 方向本身不自洽，实现取了
> 唯一自洽的那一种）。
> 本文承接 `docs/dev/cluster-auth-design.md` §14 里那条
> "`source_node` 仍未被绑定 —— 记为 open，没有关"。
> 所有事实带 `文件:行`；推测处显式标注"未验证"。

## 0. 结论

§14 那套 `identityKey` **没有绑定身份**，而且**也不可能**绑定：它的 key 是
`HMAC(cluster_secret, claim)`（`DistributedEventBus.zig:384`），**任何持有 `cluster_secret` 的人
都能推导出任何节点的 key**。所以它相对"直接 MAC 整段 json"没有额外安全性 ——
`cluster-auth-design.md` §14 自己也承认了这一点。

要真的绑定，只有一条路：**每个节点一份自己的凭证**，并在连接建立时**握手**把"这条连接是谁"
钉住。这是一次**新协议步骤**，不是现有帧的微调。

（§11 起 `identityKey` 已删除，上面那个行号指的是实现前的位置。）

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

---

## 11. 实现记录（2026-09-21）—— **§8 的五个阶段全部落地**

§10 的三件事按建议定的：接收方先发 challenge、**现在就做互证**、`setPeerKey(id, key)` 逐对端。
改动**全部**在 `src/core/DistributedEventBus.zig`（`ClusterBootstrap.zig`、Raft、`src/im/**`、
`src/api/**` 一行未动）。

### 11.1 阶段逐条

| 阶段 | 落地 | 位置 |
|---|---|---|
| 1 凭证表 + setter | `own_key: ?[32]u8`、`peer_keys: StringHashMap([32]u8)`（键归表所有）、`setOwnKey`、`setPeerKey`（`!void`，OOM 才失败）、`peerKey`（带锁读） | `:136`–`:160`、`:1336`、`:1346`、`:1365` |
| 2 握手（接收方 + 拨号方，双向） | `bindInbound`（①②③ 全做）、`bindOutbound`（读 challenge、证明自己、**要求对方也证明**）、`writeHandshake`/`readHandshake` | `:597`、`:671`、`:545`、`:563` |
| 3 绑定连接 + `source == bound_id` + 删除 `identityKey` | `Binding{id, key}`；`handleConnection` 在帧循环**之前**绑定；每帧解析后比对 `event.source_node`，不等即 `break`（丢连接，不是丢帧）；入站 MAC 密钥改成 `peer_keys[bound_id]`；`identityKey`/`claimedSource` **删除** | `:720`、`:808`、`:516` |
| 4 接线 + fail-closed | `connectToNode` 在拨号**之前**查 `peer_keys` → `error.PeerKeyMissing`；连上后同步跑 `bindOutbound`，失败即关 socket、`socket = null`（与既有"连不上"同形）；`sendEventFrame` 用自己的 key；`start()` 两条 warn | `:1394`、`:1415`、`:481`、`:313` |
| 5 文档 | 本文、`docs/DISTRIBUTED.md`、`docs/UPGRADING.md` v0.32.0、`CHANGELOG.md` | — |

### 11.2 实现期必须自己定的两件事（§10 之外）

**① §3.3 的 MAC 方向本身不自洽，实现取唯一自洽的那种。** 把 §3.3 和 §3.1 一起读：

```text
§3.1  A 持有 key_A，并且知道 key_B（"知道对端的 key"）
§3.2  拨号方用 own_key 签 claim        ⇒ 接收方用 peer_keys[claim] 验 ⇒ peer_keys[B] == key_B
§3.2  接收方用 own_key 签 mac2         ⇒ 拨号方用 peer_keys[receiver] 验 ⇒ peer_keys[A] == key_A
§3.3  出站 mac = HMAC(peer_key(对端 id), json)   ⇒ B 发 A 时用 peer_keys[A] == key_A 签
§3.3  入站 mac = HMAC(peer_key(bound_id), json)  ⇒ A 用 peer_keys[B] == key_B 验
```

最后两行要求 `key_A == key_B` —— 即**所有节点共用一把 key**，正是 §0 要消掉的东西。所以实现取：

```text
签名一律用 own_key；验签一律用 peer_keys[发送方 id]
```

事件帧：出站 `HMAC(own_key, json)`，入站 `HMAC(peer_keys[bound_id], json)`。这与 §3.2 两条
完全同形，`peer_keys[id]` 的含义也统一成一句：**`id` 这个节点自己的 key**。§3.3 那两行按此重读，
其余不动。（brief 里"出站签 peer_keys[peer_id]"的父注与 §3.2 相冲突，按同一条判据解决。）

**② 握手报文的边界**：三个报文都用与事件帧相同的 `[4-byte BE len][body]`，`len` 在**缓冲之前**
校验 `1..MAX_MESSAGE_SIZE`（与事件帧同一条理由：流已失步时猜下一个报文起点＝把任意字节交给解析器）。
② 至少 `16 + 1 + 32` 字节，③ 至少 `1 + 32`。

### 11.3 fail-closed：实现后的实际行为（对照 §5 的表）

| 场景 | 实现后的行为 |
|---|---|
| 配了凭证，拨号到没有 `peer_keys` 的对端 | `connectToNode` **先**返回 `error.PeerKeyMissing`（在 dial 之前，`peer_keys` 里没有就不开 socket，节点也不注册） |
| 握手 `claim_id` 不在 `peer_keys` | 关连接（debug 日志），**没有任何回落** |
| 握手 MAC 不对 / challenge 重放 | 关连接 |
| 绑定后帧的 `source` ≠ `bound_id` | 关连接（**整条连接**，不是只丢这一帧 —— 否则可以把冒充藏在合法帧前面） |
| 完全没配任何 key | 走既有裸帧路径，`start()` 打既有的那条 warn（措辞改成"没有凭证 / 调 `setOwnKey`"） |
| 配了 key 但收到裸帧 | 关连接 —— 认证模式下**第一个**要读的就是握手应答，裸帧不是"没有 MAC 的帧"，是**应答格式错** |
| 配了凭证但**自己没有 `own_key`** | 关连接 + `start()` 第二条 warn（以前这条是"连不上对端"，现在说得出来原因） |

另加一条实现期的收紧，设计里没写：**③ 的接收方 id 必须等于我们拨的那个 id**（`bindOutbound`），
与 §10 的 peer-id 纪律同一句话。

### 11.4 §7 的七条，逐条有用例

| # | 用例 | 位置 |
|---|---|---|
| 1 | `a claim answered with another node's key is refused`（带正对照） | `:2563` |
| 2 | `a replayed handshake is refused on a fresh connection`（捕获第一轮的应答字节，在第二条连接上原样重放；之后仍写一条本可被接受的帧，断言**连接保持关闭**） | `:2599` |
| 3 | `a frame claiming another node on a bound connection is refused, not delivered` ← **判据** | `:2650` |
| 4 | `an event frame before the handshake is refused` | `:2695` |
| 5 | `connectToNode refuses a peer with no key before it dials` | `:2736` |
| 6 | `the dialer requires the receiver to prove its own identity` 的第一个块 + `two credentialed nodes bind over the network and exchange an event`（真 socket，accept 侧 + 拨号侧一起跑） | `:2754`、`:2825` |
| 7 | 同上第二个块（同一个诚实的接收方，只是拿错钥匙签 `mac2` → 拨号方 `error.HandshakeRejected`） | `:2754` |

**#3 的用例形状**值得单说：它在**同一条连接**上先发一条 `source = "node-b"` 的帧，再发一条
`source = "node-a"` 的合法帧，断言**两条都没投递**。于是它同时区分三件事：不校验 source（两条都投）、
只丢帧不关连接（合法帧会被投）、正确实现（0）。变异 (i) 就是把这条用例打红。

### 11.5 验证

| 命令 | 结果 |
|---|---|
| `zig fmt --check src tools examples` | 0 |
| `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test --summary all -Dtest-force-run=true` | **15/15 steps succeeded；1542/1563 tests passed（21 skipped，0 failed）**，主产物 1427 pass + 21 skip（1448） |
| `bash scripts/check-production.sh` | 0（无裸 `catch {}`） |
| `bash scripts/check-deadcode.sh` | 0（src+tools 32 未超基线） |

新增 **8** 条用例（删掉 1 条已失效的 `a frame is keyed by the source it claims`，净 +7；基线
1535/1556 → 1542/1563 差的正是 +7）。

**三条变异逐条验红，都是断言红不是编译错**（都按字节还原，md5 前后一致
`8a8c1c652602d9fea23286d338ab4a9b`，`grep -c MUTATION` → 0）：

| 变异 | 红的样子（原文） |
|---|---|
| (i) 去掉 `source == bound_id` 校验 | `core.DistributedEventBus.test.a frame claiming another node on a bound connection is refused, not delivered...expected 0, found 2` / `FAIL (TestExpectedEqual)` |
| (ii) challenge 不再每条连接新取（`@memset(&challenge, 0)` 替掉 `randomSecure`） | `core.DistributedEventBus.test.a replayed handshake is refused on a fresh connection...expected 0, found 1` / `FAIL (TestExpectedEqual)` |
| (iii) 去掉 `mac2` 的常时比较 | `core.DistributedEventBus.test.the dialer requires the receiver to prove its own identity...expected error.HandshakeRejected, found void` / `FAIL (TestExpectedError)` |

(ii) 是最贴近"去掉 challenge 单次性"的形状：challenge 一旦不新鲜，捕获的应答就能在第二条连接上
复用，"绑定"退化成"任意持 key 者一次性证明过"，所以 #2 必须红。

### 11.6 被改的 fixture（有意，非弱化）

| fixture | 为什么 |
|---|---|
| `testFrame(allocator, key, json)`（**合并**原 `testFrame`/`testFrameRaw`） | 帧不再按"声称的身份"派生密钥，而是用发送方**自己的** key 签；原来那两个形状（一个走 KDF、一个走裸 key）现在是一件事 |
| `feedAuthed(bus, claim, sign_key, frame_key, frames)`（新） | 认证连接是**对话**，只写字节的 fixture 不再是"对端"。`frame_key` 与 `sign_key` 分开，才能表达"握手过、帧的 key 不对" |
| `peerAnswerChallenge` / `peerServeAsReceiver` / `ReceiverFixture`（新） | 分别是**拨号方**和**接收方**两半的测试替身；`peerAnswerChallenge` 返回它发出去的应答字节，专为 #2 的重放 |
| `feedFrame` 的文档 | 它只对**裸**路径有效（对端半边先关，认证模式下首写 challenge 就会失败），注释里写明 |
| `two writers on one socket…` | `setClusterSecret(secret)` → `setOwnKey(secret)`；验签 key 由 `identityKey(secret, "writer-node")` 改成 `secret`（发送方自己的 key） |
| `a signed frame round-trips` | 发送侧断言改成"用发送方自己的 key 签、用接收方 key 验不过"；投递侧改成一次真握手（`feedAuthed`） |
| `a frame signed with another key is dropped` / `…json changed after signing…` | 从"喂原始字节"改成"握手成功、帧的 key/内容不对"——契约没变，入口变了 |

**没有删除任何 `expect`/`assert`**；§12 的 quorum `+ 1`、§10 的 peer-id 校验、L2 的成员校验、
L1 的 HMAC helper、`serializeEvent` 的转义与漂移守卫、`seq` 重放防护、入站空闲上界**全部未动**。

### 11.7 §6 那条"每连接多一个 RTT"，它影响什么

设计里标"**未验证**：树内是否有'每事件一条连接'的用法" —— **查了，没有**：

- 连接是**每个对端一条、长期存在**的：`self.nodes` 每个 id 只留一个 `socket`，
  `connectToNode` 对已在表里的 id **直接 return**（`:1395`），`publish` 与 `heartbeatLoop` 都复用同一个
  socket（`:282`、`:438`、`:1011`、`:1030`）。
- `connectToNode` 的树内调用者只有两处，都在 `ClusterMembership`：gossip 收到 `join` 时
  （`ClusterMembership.zig:332`）与 `connectToSeed`（`:358`）。两处都是**成员变化/setup** 路径，
  不是每事件路径。
- 所以代价是"**每条连接建立时多一个 RTT**"，即节点加入/重连时多一个 RTT；稳态事件投递的
  时延与吞吐**完全不变**（帧形状、长度、MAC 长度都没变）。

**但拨号方多了一处阻塞**（这是实现引入的、设计没写到的）：`connectToNode` 现在**同步**跑完握手，
而它可能被 gossip 的 handler 调用（`ClusterMembership.zig:332` 是 `catch |err|` 吞掉的），
所以"对端 accept 了却不发 challenge"会让那个调用者最多等一个 `inbound_idle_timeout_ms`（30s，
`SO_RCVTIMEO` 已施加于拨号 socket）。**未实测**这条在最坏情况下的排队影响；要收紧就把拨号的握手
移到独立 fiber 上，本轮没做（会改变 `connectToNode` 的同步语义）。

### 11.8 仍未做（**明写**）

- **不做加密**：帧仍是明文（§9 未变）。
- **不做密钥轮换 / 撤销**：静态成员表 + 静态 key；`peer_keys` 可以被 `setPeerKey` 覆盖（最后一个
  写入者赢），但**没有撤销入口**，也没有按 kid 的双验。
- **混合版本集群未实测对跑**：硬切更硬了 —— 新侧对旧节点发的第一帧期望的是 challenge，收到的是
  事件帧；旧侧对新节点的 challenge 会当事件去解析（§14 记过：旧侧的解析器是子串匹配）。**失败形态是
  "总线连不上"，不是"看起来正常但不设防"**，但确实没有实测过混合版本。
- **Raft 那一半没动**：L1 的 `ClusterAuth` 仍是共享 PSK，`leader_id` 的可信度仍只是"持有 secret 的
  主机"（§9 已记，属于另一轮）。
- **入站连接不登记回 `self.nodes`**：绑定给了 id，但没有地址可用（入站对端是
  `dialer_ip:临时端口`），所以"反向投递仍走对端自己拨的那条连接"。这是既有形状，未改。
- **`peer_keys` 没有上界 / TTL**：只有应用写它，不是对端可控的表（与 `peer_seqs` 的区别写在这里）。
