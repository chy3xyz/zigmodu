const std = @import("std");

// ── Enums ────────────────────────────────────────────────────────

/// 菜单类型：目录、菜单、按钮
pub const MenuType = enum(u8) {
    dir = 1,
    menu = 2,
    button = 3,

    pub fn fromInt(v: u8) MenuType {
        return switch (v) {
            1 => .dir,
            2 => .menu,
            3 => .button,
            else => .button,
        };
    }
};

/// 数据范围
pub const DataScope = enum(u8) {
    all = 1,
    dept_custom = 2,
    dept_only = 3,
    dept_and_child = 4,
    self_ = 5,

    pub fn fromInt(v: u8) DataScope {
        return switch (v) {
            1 => .all,
            2 => .dept_custom,
            3 => .dept_only,
            4 => .dept_and_child,
            5 => .self_,
            else => .self_,
        };
    }
};

// ── Core Types ───────────────────────────────────────────────────

/// 角色 — 对应 system_role 表
pub const Role = struct {
    id: i64,
    name: []const u8,
    code: []const u8,
    sort: i32,
    status: u8,
    type: u8,
    remark: []const u8,
    data_scope: DataScope,
    data_scope_dept_ids: ?[]const u8,
    tenant_id: i64,
};

/// 菜单 — 对应 system_menu 表
pub const Menu = struct {
    id: i64,
    name: []const u8,
    permission: []const u8,
    menu_type: MenuType,
    sort: i32,
    parent_id: i64,
    path: []const u8,
    icon: []const u8,
    component: []const u8,
    component_name: []const u8,
    status: u8,
    visible: bool,
    keep_alive: bool,
    always_show: bool,

    pub fn isDir(self: Menu) bool { return self.menu_type == .dir; }
    pub fn isMenu(self: Menu) bool { return self.menu_type == .menu; }
    pub fn isButton(self: Menu) bool { return self.menu_type == .button; }
};

/// 角色-菜单关联
pub const RoleMenu = struct {
    id: i64,
    role_id: i64,
    menu_id: i64,
};

/// 用户-角色关联
pub const UserRole = struct {
    id: i64,
    user_id: i64,
    role_id: i64,
};

/// 菜单树节点（前端渲染用）
pub const MenuTreeNode = struct {
    id: i64,
    name: []const u8,
    path: []const u8,
    icon: []const u8,
    component: []const u8,
    component_name: []const u8,
    permission: []const u8,
    menu_type: MenuType,
    visible: bool,
    keep_alive: bool,
    always_show: bool,
    parent_id: i64,
    sort: i32,
    children: std.ArrayListUnmanaged(MenuTreeNode) = .{},

    pub fn deinit(self: *MenuTreeNode, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

/// 认证信息 — 从 JWT 解析后挂载到请求上下文
/// Authentication info populated from JWT claims.
///
/// IMPORTANT: `permissions` starts empty. The caller MUST load permissions
/// from the database after JWT verification and populate this map before
/// calling hasPermission/hasAnyPermission/hasAllPermission:
///
///   var auth = ...; // from JWT
///   try loadPermissions(&auth, auth.role_ids); // user-defined DB lookup
pub const AuthInfo = struct {
    user_id: i64,
    tenant_id: i64,
    username: []const u8,
    role_ids: []const i64,
    permissions: std.StringHashMapUnmanaged(bool) = .{},

    pub fn deinit(self: *AuthInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.role_ids);
        var it = self.permissions.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.permissions.deinit(allocator);
    }

    pub fn hasPermission(self: *const AuthInfo, perm: []const u8) bool {
        if (self.permissions.count() == 0) return false;
        return self.permissions.contains(perm);
    }

    pub fn hasAnyPermission(self: *const AuthInfo, perms: []const []const u8) bool {
        for (perms) |p| {
            if (self.hasPermission(p)) return true;
        }
        return false;
    }

    pub fn hasAllPermissions(self: *const AuthInfo, perms: []const []const u8) bool {
        for (perms) |p| {
            if (!self.hasPermission(p)) return false;
        }
        return true;
    }
};

// ── RBAC Engine ──────────────────────────────────────────────────

pub const RbacEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RbacEngine {
        return .{ .allocator = allocator };
    }

    /// 从扁平菜单列表构建权限集合
    pub fn buildPermissionSet(allocator: std.mem.Allocator, menus: []const Menu) !std.StringHashMapUnmanaged(bool) {
        var set: std.StringHashMapUnmanaged(bool) = .{};
        for (menus) |menu| {
            if (menu.permission.len > 0) {
                try set.put(allocator, menu.permission, true);
            }
        }
        return set;
    }

    /// 构建菜单树（从扁平列表 → 树结构）
    pub fn buildMenuTree(self: *const RbacEngine, menus: []const Menu, root_id: i64) !std.ArrayListUnmanaged(MenuTreeNode) {
        var nodes = std.ArrayListUnmanaged(MenuTreeNode){};
        var node_map = std.AutoHashMap(i64, *MenuTreeNode).init(self.allocator);
        defer node_map.deinit();

        for (menus) |menu| {
            if (menu.menu_type == .button) continue;
            const node = try self.allocator.create(MenuTreeNode);
            node.* = .{
                .id = menu.id,
                .name = menu.name,
                .path = menu.path,
                .icon = menu.icon,
                .component = menu.component,
                .component_name = menu.component_name,
                .permission = menu.permission,
                .menu_type = menu.menu_type,
                .visible = menu.visible,
                .keep_alive = menu.keep_alive,
                .always_show = menu.always_show,
                .parent_id = menu.parent_id,
                .sort = menu.sort,
            };
            try node_map.put(menu.id, node);
        }

        // 建立父子关系
        var it = node_map.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.parent_id == root_id) {
                try nodes.append(self.allocator, node);
            } else {
                if (node_map.get(node.parent_id)) |parent| {
                    try parent.children.append(self.allocator, node);
                } else {
                    try nodes.append(self.allocator, node);
                }
            }
        }

        sortTreeNodes(nodes);
        return nodes;
    }

    /// 过滤菜单树：只保留用户有权访问的节点
    pub fn filterTreeByPermission(self: *const RbacEngine, tree: *std.ArrayListUnmanaged(MenuTreeNode), auth: *const AuthInfo) void {
        var i: usize = 0;
        while (i < tree.items.len) {
            var node = &tree.items[i];
            self.filterTreeByPermission(&node.children, auth);

            if (node.permission.len > 0 and !auth.hasPermission(node.permission)) {
                if (node.menu_type == .menu) {
                    node.deinit(self.allocator);
                    _ = tree.orderedRemove(i);
                    continue;
                }
                if (node.children.items.len == 0) {
                    node.deinit(self.allocator);
                    _ = tree.orderedRemove(i);
                    continue;
                }
            }
            i += 1;
        }
    }

    fn sortTreeNodes(nodes: std.ArrayListUnmanaged(MenuTreeNode)) void {
        const Ctx = struct {
            fn less(_: void, a: MenuTreeNode, b: MenuTreeNode) bool {
                if (a.sort != b.sort) return a.sort < b.sort;
                return a.id < b.id;
            }
        };
        std.sort.pdq(MenuTreeNode, nodes.items, {}, Ctx.less);
        for (nodes.items) |*node| {
            sortTreeNodes(node.children);
        }
    }
};

// ── Permission constants ─────────────────────────────────────────

pub const Permissions = struct {
    pub const system_user_list = "system:user:query";
    pub const system_user_create = "system:user:create";
    pub const system_user_update = "system:user:update";
    pub const system_user_delete = "system:user:delete";
    pub const system_user_export = "system:user:export";
    pub const system_user_import = "system:user:import";

    pub const system_role_list = "system:role:query";
    pub const system_role_create = "system:role:create";
    pub const system_role_update = "system:role:update";
    pub const system_role_delete = "system:role:delete";

    pub const system_menu_list = "system:menu:query";
    pub const system_menu_create = "system:menu:create";
    pub const system_menu_update = "system:menu:update";
    pub const system_menu_delete = "system:menu:delete";

    pub const system_dept_list = "system:dept:query";
    pub const system_dept_create = "system:dept:create";
    pub const system_dept_update = "system:dept:update";
    pub const system_dept_delete = "system:dept:delete";

    pub const system_dict_list = "system:dict:query";
    pub const system_dict_create = "system:dict:create";
    pub const system_dict_update = "system:dict:update";
    pub const system_dict_delete = "system:dict:delete";

    pub const system_tenant_list = "system:tenant:query";
    pub const system_tenant_create = "system:tenant:create";
    pub const system_tenant_update = "system:tenant:update";
    pub const system_tenant_delete = "system:tenant:delete";
};
