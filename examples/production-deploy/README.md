# production-deploy — TLS 终结、边车与进程守护参考

这不是一个可运行的 Zig 应用，而是一份**部署拓扑参考**：ZigModu 的 stdlib 没有
TLS server（`docs/PRODUCTION_ROADMAP.md`、`Server.tls_front` 注释），生产 TLS
一律在**边车 / 网关**终结，后端说 h2c 或明文 HTTP。

```
        ┌────────────┐   TLS (443)   ┌──────────────────────┐  h2c/HTTP  ┌──────────────┐
client ─┤  网关/边车  ├──────────────►│  zigmodu 服务实例 N  │◄───────────┤  supervisor  │
        │ nginx/envoy│               │  单进程 · 无状态      │  Restart   │ systemd / k8s│
        └────────────┘               └──────────────────────┘            └──────────────┘
```

要点（每条都对应一个真实故障模式）：

| 决策 | 原因 |
|------|------|
| TLS 在边车终结，后端 h2c/明文 | 框架不实现 TLS server；把证书轮换、ALPN、HTTP/2 版本协商交给成熟组件 |
| 网关 → 后端用 **h2c**（HTTP/2 cleartext） | 复用 `Server.setHttp2Enabled(true)` 的多路复用与 gRPC 路径；`docs/BEST_PRACTICES.md` |
| 进程守护 `Restart=always` / `restartPolicy: Always` | panic 不可捕获：任何请求路径 panic 都会结束进程。**重启是最后一道可用性防线** |
| 应用 root 接 `pub const panic = zmodu.panicHook;` | 让 stderr 带上"panic 时正在处理哪个请求"，重启后能定位 |
| 后端设 `max_connections` + `header_timeout_ms` | 边车只是转发；连接洪泛/slowloris 会穿透到后端 |
| 健康检查用 `/health/live`（liveness）+ `/health/ready`（readiness） | 存活与就绪语义不同：依赖挂了应摘流量而不是重启 |
| 每实例 `max_connections ≈ 预期并发 × 2` | 超过后直接拒连（或 503），比 OOM 优雅 |
| 启动跑 `zigmodu.Preflight`（env / JWT secret / DB / 迁移 / 时钟） | 带病运行的进程比拒绝启动的进程贵得多 |
| JWT secret 用 `JwksKeyRing` 承载，轮换只切主密钥 | 直接改 secret 重启 = 全员强制重登 |
| 多副本的 cron / 迁移配 `DistributedLock` | 每副本各跑一遍 = 重复副作用与并发 DDL |

## 文件

| 文件 | 用途 |
|------|------|
| `nginx.conf` | nginx 作为 TLS 终结 + h2c 反代（含超时、限连、健康检查） |
| `envoy.yaml` | Envoy 版本（ALPN h2、`/health` 探针、上游健康检查） |
| `docker-compose.yml` | 本地跑通「nginx + 两个后端副本」的最小拓扑 |
| `k8s.yaml` | Deployment/Service/探针/Prometheus 注解 + HPA 片段 |
| `zigmodu.service` | systemd 单元（`Restart=always`、`LimitNOFILE`、环境变量） |

## 后端启动参数（对应各文件）

```bash
HTTP_PORT=8080
HTTP_MAX_CONNECTIONS=4096        # Server.fromEnv
HTTP_HEADER_TIMEOUT_MS=10000
WS_WRITE_TIMEOUT_MS=10000        # 慢 WS 客户端不再无限阻塞写线程
JWT_SECRET=<来自 Secret 管理，勿写进镜像>
```

`Server.fromEnv(io, allocator, init.environ_map)` 会读取以上变量。

## 冒烟

```bash
cd examples/production-deploy
docker compose up --build
curl -sfk https://localhost:8443/health/live     # {"status":"UP"}
curl -sk  https://localhost:8443/metrics | head  # Prometheus 文本
```

## 为什么不做进程内 TLS

- stdlib 无 TLS server；引入第三方 = 打破"零依赖"这条最硬的卖点。
- 证书轮换、CRL/OCSP、H2 ALPN 协商、加密套件策略属于运维面，边车有成熟实现。
- sidecar 拓扑可整体替换（nginx/envoy/云 LB），不影响应用代码。

后续若确实需要"单二进制自带 TLS"，属于路线图级别的新增（见
`docs/PRODUCTION_ROADMAP.md`「单进程单点与原位隔离」同类决策记录）。
