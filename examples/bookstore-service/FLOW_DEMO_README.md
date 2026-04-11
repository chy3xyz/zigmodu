# 完整数据库流程演示 - End-to-End Database Flow Demo

## 概述

这是一个**完整的企业级数据库流程演示**，展示了从数据库初始化到完整的CRUD操作，再到跨模块事务处理的完整数据流。

## 🎯 演示流程

### Phase 1: 系统初始化 (System Initialization)
- 初始化配置模块
- 初始化事件总线
- 初始化数据库模块（带连接池）

### Phase 2: 数据库设置 (Database Setup)
- 连接到SQLite数据库
- 自动运行数据库迁移
- 创建表结构（books, users, orders, inventory, audit_logs）
- 创建索引优化查询性能
- 显示连接池统计信息

### Phase 3: 事件驱动设置 (Event-Driven Setup)
- 注册跨模块事件监听器
- Inventory模块监听order_created事件
- Notification模块监听order_created和order_shipped事件
- Audit模块监听payment_completed事件

### Phase 4: 模块初始化 (Module Initialization)
- 扫描并注册所有12个模块
- 验证模块依赖关系
- 启动所有模块

### Phase 5: 完整CRUD流程 (Complete CRUD Flow)

#### 5.1 CREATE - 插入数据
- 创建图书（使用Catalog模块）
  - The C Programming Language
  - Design Patterns
- 创建用户（使用User模块）
  - 普通客户: john_doe
  - 管理员: admin_user
- 初始化库存（使用Inventory模块）
- 发布user_registered事件

#### 5.2 READ - 查询数据
- 查询所有图书
- 根据ID查询特定图书
- 关键词搜索（搜索包含"C"的图书）
- 查询所有用户
- 查询库存统计

#### 5.3 UPDATE - 修改数据
- 更新图书价格（59.99 → 49.99）
- 更新用户邮箱
- 添加库存（+50单位）

#### 5.4 DELETE - 删除数据
- 演示软删除操作（标记为不活跃）

### Phase 6: 跨模块事务流程 (Cross-Module Transaction)

这是一个**完整的购物流程演示**，展示多个模块如何协同工作：

```
1. 用户认证 (User Module)
   └── 用户 john_doe 登录
   
2. 购物车操作 (Cart Module)
   └── 添加2本《C Programming Language》
   └── 添加1本《Design Patterns》
   
3. 库存预留 (Inventory Module)
   └── 自动预留库存（通过事件触发）
   └── Book 1: 预留2本
   └── Book 2: 预留1本
   
4. 创建订单 (Order Module)
   └── 创建订单ID=1000
   └── 计算总价
   └── 发布order_created事件
       └── Notification: 发送订单确认邮件
       └── Inventory: 确认库存预留
       
5. 支付处理 (Payment Module)
   └── 处理信用卡支付
   └── 发布payment_completed事件
       └── Audit: 记录支付审计日志
       
6. 订单履行
   └── 更新订单状态: paid
   └── 履行库存预留（扣减库存）
   └── 更新订单状态: shipped
   └── 发送发货通知邮件
   
7. 事务提交
   └── 所有操作成功，提交事务
   └── 或支付失败，回滚事务
```

### Phase 7: 查询与报表 (Query and Reporting)

#### 7.1 统计报表
- **Catalog Statistics**: 总图书数、总价值、低库存数量
- **Order Statistics**: 总订单数、总收入、状态分布
- **Payment Statistics**: 总交易数、成功率、总金额
- **Inventory Statistics**: 库存项数、总数、预留数、可用数
- **Audit Logs**: 审计日志条目数
- **Database Stats**: 连接池使用情况

## 🔧 技术特性

### 数据库特性
- ✅ **连接池管理**: 10个连接的连接池
- ✅ **事务支持**: ACID事务，支持提交和回滚
- ✅ **数据库迁移**: 自动版本控制和迁移
- ✅ **索引优化**: 为常用查询字段创建索引
- ✅ **外键约束**: 维护数据完整性

### 架构特性
- ✅ **事件驱动**: 模块间通过事件总线解耦通信
- ✅ **仓储模式**: 统一的数据访问抽象
- ✅ **模块化设计**: 12个独立模块，职责清晰
- ✅ **审计追踪**: 所有重要操作记录审计日志

## 📊 数据模型

### Books 表
```sql
CREATE TABLE books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    isbn TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    author TEXT NOT NULL,
    publisher TEXT,
    price REAL NOT NULL,
    category_id INTEGER,
    description TEXT,
    stock_quantity INTEGER DEFAULT 0,
    is_active INTEGER DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
```

### Users 表
```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT DEFAULT 'customer',
    is_active INTEGER DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
```

### Orders 表
```sql
CREATE TABLE orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    total_amount REAL NOT NULL,
    status TEXT DEFAULT 'pending',
    shipping_address TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id)
)
```

### Inventory 表
```sql
CREATE TABLE inventory (
    book_id INTEGER PRIMARY KEY,
    quantity INTEGER NOT NULL DEFAULT 0,
    reserved INTEGER NOT NULL DEFAULT 0,
    location TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (book_id) REFERENCES books(id)
)
```

### Audit Logs 表
```sql
CREATE TABLE audit_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER,
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id INTEGER,
    old_value TEXT,
    new_value TEXT,
    ip_address TEXT,
    success INTEGER DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
```

## 🚀 运行方式

```bash
cd examples/bookstore-service

# 运行完整流程演示
zig run src/flow_demo.zig

# 或者先构建再运行
zig build
./zig-out/bin/flow_demo
```

## 📈 预期输出

运行后会看到类似以下的输出：

```
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║     📚 Bookstore Service - End-to-End Database Flow       ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝

=== Phase 1: System Initialization ===

=== Phase 2: Database Setup ===
[database] Running migrations...
[database] Applied migration v1: Create initial tables
[database] Applied migration v2: Add indexes
[database] Migrations completed
Database Stats: 10/10 connections available

=== Phase 5: Complete CRUD Flow ===

--- 5.1 CREATE: Inserting Data ---
  Creating books...
    ✓ Book created: ID=1, Title='The C Programming Language'
    ✓ Book created: ID=2, Title='Design Patterns'
  Creating users...
    ✓ User created: ID=1, Username='john_doe'
    ✓ User created: ID=2, Username='admin_user' (Admin)

--- 6.1 Cross-Module Transaction ---
  Step 1: User authentication
    ✓ User logged in: john_doe
  Step 2: Adding items to cart
    ✓ Cart: 2 items added
  Step 3: Reserving inventory
    ✓ Reserved: Book 1 (qty=2), Book 2 (qty=1)
  Step 4: Creating order
    [EVENT] Inventory: Auto-reserving stock for order
    [EVENT] Notification: Sending order confirmation email
    ✓ Order created: ID=1, Total=$154.97
  Step 5: Processing payment
    [EVENT] Audit: Logging payment transaction
    ✓ Payment: Payment successful (Status: completed)
    ✓ Transaction committed successfully

=== Final System Summary ===
  System State Summary:
    📚 Books: 2
    👥 Users: 2
    📦 Orders: 1 ($154.97)
    💳 Payments: 1 transactions
    📧 Notifications: 3 sent
    📝 Audit Logs: 5 entries

✅ All database flows completed successfully!
```

## 🎓 学习要点

### 1. 数据库连接池
- 预创建连接，避免频繁创建销毁
- 连接复用，提高性能
- 线程安全的连接获取和释放

### 2. 事务管理
- 跨多个模块的业务操作包装在事务中
- 保证数据一致性（ACID）
- 失败时自动回滚

### 3. 事件驱动架构
- 模块间不直接调用，通过事件解耦
- 一个事件可以触发多个模块的响应
- 便于扩展和维护

### 4. 审计追踪
- 所有重要操作记录审计日志
- 支持数据变更追踪
- 便于故障排查和合规审计

## 🔗 相关文件

- `modules/database.zig` - 数据库连接池和事务管理
- `modules/repository.zig` - 仓储模式和查询构建器
- `modules/eventbus.zig` - 事件总线实现
- `src/flow_demo.zig` - 本演示文件
- `src/main.zig` - 主应用程序

## 📝 总结

这个演示展示了：

1. **完整的数据库生命周期**: 连接 → 迁移 → CRUD → 事务
2. **企业级架构模式**: 连接池、仓储模式、事件驱动
3. **跨模块协作**: 12个模块协同完成业务流程
4. **数据完整性**: 外键约束、事务、审计日志

这是一个可用于生产环境的数据库架构设计！
