# zmsaas — SaaS 业务框架参考工程（zigmodu 后端 + SolidStart 前端）

一个可直接运行的完整示例：**zigmodu 后端**（org 隔离的 `orders` 业务模块，
由 `zmodu saas` 生成）+ **saas-solidjs 前端**（管理页 + `zmoduFetch` REST
client，由 `zsaas/scripts/gen-business.mjs` 生成）。

## 结构

```
examples/zmsaas/
├── backend/              # zigmodu 后端（原 saas-kit 形态）
│   ├── build.zig / build.zig.zon / db_link.zig
│   └── src/
│       ├── main.zig      # 接线：sqlite + JWT/RBAC 中间件栈 + Router.mountAll
│       ├── auth/root.zig # 公开 login（签发租户 JWT）
│       ├── db/schema.zig # orders 表 + RBAC 授权 + 种子数据
│       ├── middleware/   # 框架最佳实践鉴权栈（沿用 tenant-mgmt）
│       └── modules/orders/  # zmodu saas 生成：model/persistence/service/api/module/root
├── frontend/             # saas-solidjs 前端（已排除 node_modules/.git/.output）
│   └── src/
│       ├── libs/apiClient.ts           # 类型化 zigmodu REST client（信封 + Bearer + 错误映射）
│       ├── components/data/            # 数据驱动收敛：DataTable.tsx + EntityForm.tsx
│       ├── models/Orders.ts            # 实体类型 + 字段 schema（表/表单共用）
│       └── routes/dashboard/orders/    # index.tsx CRUD 演示页（login → list → create/edit/delete）
├── scripts/dev.sh        # 双进程启动（后端 + 前端）
└── README.md
```

## 运行

```bash
# 一键双进程
bash examples/zmsaas/scripts/dev.sh

# 或分开：
cd examples/zmsaas/backend && zig build run          # http://127.0.0.1:18080
cd examples/zmsaas/frontend && npm install && npm run dev   # http://localhost:3000
```

后端 API：

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:18080/api/v1/auth/login | jq -r .token)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18080/api/v1/orders
```

无 token → 401；token 只访问自己 `org_id` 的数据（种子 org 1）。

## 前端 CRUD 收敛（DataTable / EntityForm）

`/dashboard/orders` 演示了「数据驱动 CRUD」：页面不手写表格行/表单控件，
只声明列与字段 schema：

- `DataTable<T>`：列定义（key/header/render）、分页、loading/空态、行操作；
- `EntityForm`：字段定义（text/number/textarea/select + required）→ 自动渲染、
  必填校验、提交/取消；
- `models/Orders.ts`：`Order` 类型 + `orderFields` schema，两端共用，新增模块
  照此收敛；
- `libs/apiClient.ts`：解析后端信封（`{code,items,total}` / `{code,data}`），
  401/非零 code 统一抛错，路径拼接兼容带/不带尾斜杠的 `VITE_API_URL`。

## 重新生成业务模块

```bash
# 改 zsaas/examples/orders.model.json 后：
zmodu saas zsaas/examples/orders.model.json --out examples/zmsaas/backend/src/modules
node zsaas/scripts/gen-business.mjs zsaas/examples/orders.model.json examples/zmsaas/frontend
```

新增实体 → 追加到模型文件 → 两端重新生成（schema 记得同步 `db/schema.zig`）。
