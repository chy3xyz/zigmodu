# smuggling-envoy — CL/TE 走私的第二个真实拓扑（Envoy 在前）

`../smuggling-e2e`（nginx 拓扑）关掉的是 readiness B-15 的 nginx 一条腿；本目录是同一断言
在**另一个前端解析器**上的复跑：Envoy。不变式与 nginx 版逐字相同：

> **后端服务过的每一个请求，都是网关收到过的请求。**

两边都可观测：Envoy 的 access log 按 `METHOD PATH STATUS DETAILS` 记每条转发请求，探针
（复用 `../smuggling-e2e` 的 `smuggling-probe`，同一个二进制、同一后端行为）按
`REQLOG METHOD path` 记每条 dispatched 请求。后端服务了、网关没转发的请求 = 走私原语，
按定义成立。

```bash
cd examples/production-deploy/smuggling-envoy
./run.sh              # 没有 docker 就 SKIP（exit 0）
./run.sh --require    # 没有 docker 算失败（CI 用）
```

需要：docker（守护进程在跑 + compose 插件）、python3、Zig 工具链。镜像固定
`envoyproxy/envoy:v1.31.10`（可用 `ENVOY_IMAGE` 覆盖；换版本请先重跑本目录再改
`PAYLOAD_TABLE` 里的期望 —— 那些数字是这个版本的实测行为）。

端口：`APP_PORT`（探针，默认 18290）/ `GW_PORT`（Envoy 入口，默认 18291），与 nginx 版
的 18080–18082 错开，两个拓扑可以同时跑。`envoy.yaml.template` 里上游端口用 `@APP_PORT@`
占位，`run.sh` 渲染到临时目录再挂载 —— envoy.yaml 同样不展开环境变量（nginx 模板踩过的
坑，见 `../smuggling-e2e/README.md`）。

## 与 nginx 版的结构差异（都是有意为之）

- **一个监听器，不是两个**：nginx 的定界行为取决于 `proxy_request_buffering`；Envoy 没有
  这个开关 —— 它总是把 body 流式转发，且默认把合法的 `Transfer-Encoding: chunked`
  **原样保留**到上游。这正是后端自身的 TE 拒绝（对照 2/4）在本拓扑里是承重墙的原因：
  每个 TE 形载荷都真的依赖它，并且都在线缆上断言到了。
- **Envoy 自身的默认拒绝被单独断言**：codec 级拒绝的 access log 是
  `- - 400 http1.content_length_and_chunked_not_allowed`（没有 method/path，所以不计入
  「转发数」）。脚本按载荷断言这些行各出现一次 —— 「Envoy 自己拒了」的证据来自 Envoy
  自己的日志，不是从响应码反推。
- **barrier + await 代替固定 sleep 0.4**：Envoy 的 access log 是异步刷盘的，一行要在请求
  完成后 1–10 s（实测，macOS/OrbStack）才出现在 `docker compose logs` 里，nginx 是立即。
  脚本在快照前先等网关计数器稳定（barrier，防止上一条载荷的迟到行被记到本条头上），发送
  后**有界等待（≤40 s）计数器到达本条期望值**再精确断言（await_gw）。等待只消化日志延迟：
  `-ge` 等待 + 事后精确相等断言让"多转发"变红，超时也是红，永远等不出绿。
- **每条载荷钉死期望值**：状态码、网关/后端增量、codec 拒绝行三者全部钉在固定镜像的实测
  行为上。未来 Envoy 版本改了定界行为，这张表变红而不是静默通过。

四条对照与 nginx 版相同（探测端非空转 / 后端裸拒 TE / 网关路径端到端 / 不变式能红）。

## 实测（2026-10-08，macOS + OrbStack，envoyproxy/envoy:v1.31.10，linux/arm64）

```
PAYLOAD              RESP RESPONSE       G+B        CODEC    VERDICT
cl-te-conflict       1    HTTP 400        +0/+0      +1       ok
te-cl-conflict       1    HTTP 400        +0/+0      +1       ok
te-chunk-ext-line    1    HTTP 400        +1/+0      -        ok
cl-space-spacing     1    HTTP 404        +2/+2      -        ok
te-dup-te            1    HTTP 501        +0/+0      +1       ok
```

读法（与 nginx 版逐项对照）：

- **`cl-te-conflict` / `te-cl-conflict`** —— Envoy 的 HTTP/1 codec 直接 400
  （`http1.content_length_and_chunked_not_allowed`），后端一个字节都没收到。与 nginx 的
  `+1/+0` 不同的是：nginx 把它当成一条「收到的请求」记 access log 后拒绝，Envoy 在 headers
  完整前拒绝、access log 没有 method/path（`+0/+0`）。两种都是「前端掐断」。
- **`te-chunk-ext-line`** —— Envoy 不 de-chunk：把 chunked 原样转给上游，后端解析器按对照
  2/4 的分支 400 拒掉（`POST /ping 400 via_upstream`，`+1/+0`：转发 1、dispatch 0）。
  nginx 版这里是 `+1/+1 404`（nginx de-chunk 后后端当真请求路由了）。洞在两边都关着，
  关的人不同：nginx 靠规范化，Envoy 拓扑靠后端自己的拒绝 —— 这就是控制 2/4 承重的含义。
- **`cl-space-spacing`** —— `+2/+2`，与 nginx 相同：尾随字节被当成第二个流水线请求，
  网关与后端对边界看法一致，良性 pipelining，不是走私。
- **`te-dup-te`** —— Envoy 501（`http1.invalid_transfer_encoding`），nginx 是 400。
  都拒，拒绝码不同。

结论与 nginx 版一致：**发现②在 Envoy 拓扑下同样不成立**（后端不按 TE 定界、Envoy 对
CL+TE 冲突与重复 TE 默认拒绝；唯一过境的 TE 形状被后端自己 400）。

## 这个用例不覆盖什么

- **没有 HTTP/2 前端**：这里是明文 HTTP/1.1 反代（`codec_type: HTTP1`）。h2 前端的
  走私面是另一类（`:authority`/伪头混淆），不在此断言。
- **没有 TLS 终结那一层**：直连 Envoy 的明文 18291，绕过证书。
- 只跑 IPv4 环回、单机；Envoy 只测默认配置（没开 `allow_chunked_length` 之类的开关 —
  那正是要断言的默认值）。
