# smuggling-e2e — CL/TE 走私的真实拓扑用例

`docs/dev/security-audit-v0.31.0.md` 的发现②（请求边界只认 `Content-Length`）此前
是**读代码推出来的**；修复同时落了进程内测试（`src/api/Server.zig:4649+`、`:4971+`）。
但解析器只是一半 —— 走私 bug 的另一半在**前置代理的定界行为**里，进程内测试看不见
那一半。这个用例把 nginx 放到前面（就是本仓库 `nginx.conf` 的那套拓扑），在**线缆上**
断言。

```bash
cd examples/production-deploy/smuggling-e2e
./run.sh              # 没有 docker 就 SKIP（exit 0）
./run.sh --require    # 没有 docker 算失败（CI 用）
```

需要：docker（守护进程在跑）、python3、Zig 工具链。

## 断言是什么

不是"响应看起来对"，而是：

> **后端服务过的每一个请求，都是网关收到过的请求。**

两边都可观测：nginx 按 `METHOD URI` 记每条收到/转发的请求，探针按 `REQLOG METHOD path`
记每条自己收到的请求。**后端服务了、而网关根本没收到**的请求 —— 那就是走私原语，按
定义成立，不需要解释。

计数器都在线取值，所以脚本先跑三条对照，证明这个不变式**能红**：

| 对照 | 期望 | 证明什么 |
|------|------|----------|
| 1/4 直接 `GET /admin` 打到后端 | 后端 +1 | 探测端不是空转的 |
| 2/4 直接发一条 `Transfer-Encoding` 给后端 | 400，且不入 handler | 网关之外的第二道防线在线缆上也成立 |
| 3/4 经网关 `GET /admin` | 网关 +1、后端 +1 | 比较本身可用 |
| 4/4 绕过网关直接打后端 | 后端 > 网关 | **不变式能报错** —— 否则下面的绿没有意义 |

## 载荷（每条都是"客户端一次写入"）

| 载荷 | 形状 |
|------|------|
| `cl-te-conflict` | `Content-Length` 在前、`Transfer-Encoding` 在后 |
| `te-cl-conflict` | `Transfer-Encoding` 在前、`Content-Length` 在后 |
| `te-chunk-ext-line` | chunk-size 行写成 `1;GET /admin HTTP/1.1`（旧解析器会把它当请求行） |
| `cl-space-spacing` | `Content-Length:5`（无空格）+ 尾随请求 |
| `te-dup-te` | 两个 `Transfer-Encoding` |

两个网关端口，因为定界行为取决于网关是否缓冲请求体：

- `:18081` `proxy_request_buffering on`（nginx 默认）
- `:18082` `proxy_request_buffering off`

## 实测（2026-09-21，macOS，nginx:1.27-alpine）

```
PAYLOAD              GATEWAY   RESP RESPONSE       G+B        VERDICT
cl-te-conflict       buffered  1    HTTP 400       +1/+0      ok
cl-te-conflict       streamed  1    HTTP 400       +1/+0      ok
te-cl-conflict       buffered  1    HTTP 400       +1/+0      ok
te-cl-conflict       streamed  1    HTTP 400       +1/+0      ok
te-chunk-ext-line    buffered  1    HTTP 404       +1/+1      ok
te-chunk-ext-line    streamed  1    HTTP 404       +1/+1      ok
cl-space-spacing     buffered  1    HTTP 404       +2/+2      ok
cl-space-spacing     streamed  1    HTTP 404       +2/+2      ok
te-dup-te            buffered  1    HTTP 400       +1/+0      ok
te-dup-te            streamed  1    HTTP 400       +1/+0      ok
```

`G+B` 列是"网关收到数 / 后端收到数"的增量。读法：

- **`+1/+0`** —— nginx 直接 400，后端一个字节都没收到。CL 与 TE 同时出现时 nginx
  自己就先拒了，这是发现②里"与按规范解析的代理产生分歧"的那条路被前置代理掐断。
- **`+1/+1` / `+2/+2`** —— nginx 把请求体**规范化**后转发（de-chunk 或改写成
  `Content-Length`），后端收到的条数与网关收到的条数一致。`cl-space-spacing` 的 `+2`
  是 nginx 把尾随字节当成**第二个流水线请求**转发 —— 网关和后端对边界的看法一致，
  所以是良性的 pipelining，不是走私。
- 后端单独面对裸 `Transfer-Encoding` 时是 400（对照 2/4），所以"代理若真把 TE 转上来"
  这条分支也有线缆证据，而不只是进程内测试。

结论：**发现②在真实拓扑下不成立**（旧行为的形状需要后端忽略 TE 而代理按 TE 定界；
现在代理不转发 TE、后端也不接受 TE）。

## 这个用例不覆盖什么

- **没有 Envoy**：`envoy.yaml` 是另一套解析器，没测。
- **没有 HTTP/2 前端**：这里是明文 HTTP/1.1 反代。
- **没有 TLS 终结那一层**：`run.sh` 直连 nginx 的明文 18081/18082，绕过证书。
- 只跑 IPv4 环回、单机。
