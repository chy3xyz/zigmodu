# Cluster mTLS sidecar — 可跑的 A-2 参考拓扑

`docs/DISTRIBUTED.md`「传输加密边界（A-2 定界）」把集群面（Raft 端口 +
分布式事件总线）定为：**框架内明文 TCP + 逐帧 HMAC-SHA256（认证+完整性，
不是机密性）；跨主机的机密性由边车/服务网格终结 mTLS 负责**。这份示例把
那张拓扑图变成可执行物：3 个 `cluster-node`（`zig build cluster-node` 产物）
各自配一个 nginx stream 边车，跑出一个完整集群。

```
            ┌──────────────────────── docker network 172.28.0.0/24 ───────────────────────┐
            │                                                                             │
  netns: sidecar1 (172.28.0.11)                                            sidecar2 ...   │
  ┌───────────────────────────────────┐                                                   │
  │  cluster-node n1                  │        唯一过网的一段（mTLS，双向验证书）          │
  │   raft 127.0.0.1:9501 ◄──┐        │   sidecar1:9601 ═══════════════ sidecar2:9601     │
  │   bus  127.0.0.1:9502 ◄──┼── iptables lockdown（非 loopback 一律 DROP）                │
  │        ▲                 │        │   sidecar1:9602 ═══════════════ sidecar2:9602     │
  │        │ loopback        │        │         ▲                          │              │
  │  nginx sidecar1          │        │         │ 127.0.0.1:19702/19802    │ 127.0.0.1:950x│
  │   ingress 0.0.0.0:9601/2 │        │   node1 出站 dial loopback ──► nginx 出站封装     │
  │   egress  127.0.0.1:1970x/1980x   │                                                   │
  └───────────────────────────────────┘                                                   │
```

- **入向**：边车在 `0.0.0.0:9601/9602` 终结 mTLS（`ssl_verify_client on`），
  转发到 loopback 上的明文端口。
- **出向**：节点照常 dial `id@host:port`，只是 host 写成 `127.0.0.1`、端口是
  本机边车的 egress 监听（raft 1970&lt;对端序号&gt;、bus 1980&lt;对端序号&gt;），
  边车封装 mTLS 发到对端边车。
- **锁口**：框架目前把集群端口绑在 `0.0.0.0`（没有 bind-host 配置项），所以
  明文端口在 docker 网络上**本来可达**——边车入口脚本用 iptables 把
  9501/9502 收成仅 loopback（失败即拒启，`LOCKDOWN=off` 可演示绕过）。
  生产上等价物是 NetworkPolicy / 安全组，不是应用配置。

## 跑一遍

```bash
cd examples/production-deploy/cluster-sidecar
./run.sh            # 无 docker 时自动 skip；--require 则强制
```

`run.sh` 依次断言（全部可证伪，详见脚本头注释）：

1. 收敛判定打在每个节点的**最新** `RAFT_STATE` 上：三节点指认同一 leader、
   同一 term、恰好一个 `state=leader`（不看历史——raft 允许重选，数"历史
   上出现过的 leader id"既是错的断言，也确实掩盖过一次接线 bug）；且全程
   **零** `not authenticated` / `PEER_REPLY_REFUSED` / `RAFTID_DROP`（本示例
   里帧认证失败只可能是接线错误，不是背景噪声）。每节点 `VIEW members=3`
   （Raft 流量真过了边车）；
2. 每节点总线 `MESH peer=<id> state=connected` × 2（总线流量也过了边车）；
3. 同网络的探针容器**连不上**任何节点的明文 9501（绕过被 iptables 关掉）；
4. 无客户端证书的对端被 9601 拒绝——注意 nginx stream 的执行点是
   **握手后**（`ngx_stream_ssl_handler` 在 SSL phase 查不到对端证书就终结
   会话）：握手本身会"完成"，随后连接立刻被关、一个字节都不会被转发；
   双信号断言：客户端侧 `timeout 8` 不得触发（连接若 8 秒还活着 = 被透传
   到明文口 = fail-open，立即 FAIL），服务端侧边车日志必须出现
   `client sent no required SSL certificate`；
   带 node2 证书的握手成功且进入转发（`Verify return code: 0`）；
5. SIGTERM 后三节点全部 `CN SHUTDOWN clean`。

手动分步（等价于 run.sh 的前半段）：

```bash
./gen-certs.sh                # certs/ 下生成 CA + node{1,2,3} 证书 + cluster.env
docker compose build          # node 镜像在容器里编 zig build cluster-node（首跑慢）
docker compose up -d
docker compose logs -f node1  # 等 LEADER_ELECTED / VIEW members=3 / MESH connected
docker compose stop && docker compose down -v
```

## 两层凭证，各管各的

| 层 | 凭证 | 回答的问题 |
|----|------|-----------|
| 传输（边车 mTLS） | `certs/node{1,2,3}.crt/key`（CA 签发，SAN=节点 IP） | "这段连接对端是不是集群 PKI 成员" + 线上字节加密 |
| 帧（框架自带，A-1/A-3） | `certs/cluster.env` 里的 `CLUSTER_SECRET` / `BUS_KEY` / `KEY_N*` | "这个**帧**是不是节点 n2 签的"（逐帧 HMAC-SHA256、身份、防重放） |

边车被绕过或证书被误发时，帧层 HMAC 仍然挡注入/冒充；两者**不互相替代**。
节点身份自始至终由帧层钉住——所以节点 dial 的是 loopback 边车地址，对端按
key 验身份，与源 IP 无关，这个拓扑才成立。

## 边界与诚实声明

- **demo 级 PKI**：`gen-certs.sh` 用 825 天自签 CA、密钥平铺在 `cluster.env`。
  生产请用正式 CA / cert-manager / SecretsManager 下发。证书 SAN **同时带
  `IP:` 与 `DNS:` 两种形式的节点地址**——nginx 的 upstream 校验
  （`proxy_ssl_verify`）走 X509_check_host 路径，**不查 iPAddress SAN**，
  只带 IP SAN 会被拒（"upstream SSL certificate does not match"，nginx
  1.27.5 实测；DNS 形条目按字符串字面匹配通过）。
- **“最后一跳”是 loopback**：节点与边车共享 netns（`network_mode:
  service:sidecarN`），明文段不出命名空间——这正是 A-2 定界要求的
  "边车必须与节点同主机/同 Pod"。
- **绕过面靠锁口而非配置**：框架绑 `0.0.0.0` 是现状；本示例用 iptables
  把明文端口收成 loopback-only 作为部署侧答案。k8s 里对应 Pod 级
  NetworkPolicy。框架若日后长出 bind-host 配置，这层可以简化。
- **对等地址只认字面 IP**（框架 peer 语法无 DNS），所以 compose 用静态
  IPAM；换编排系统时把 IP 分配换成你们的服务发现即可，边车配置不变。
- 本示例是**参考拓扑**，不进 CI 门禁（与 `../smuggling-e2e` 一样按需跑）；
  改动集群传输后建议 `./run.sh --require` 一遍。
