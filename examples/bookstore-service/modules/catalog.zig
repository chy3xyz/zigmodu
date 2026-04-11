const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Catalog Module - 图书目录管理模块
/// 提供图书 CRUD、分类、搜索等功能
/// ============================================
pub const CatalogModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "catalog",
        .description = "Book catalog management with search and categorization",
        .dependencies = &.{"database"},
    };

    var books: std.ArrayList(Book) = undefined;
    var allocator: std.mem.Allocator = undefined;
    var book_id_counter: u64 = 1;

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        books = std.ArrayList(Book){};
        std.log.info("[catalog] Catalog module initialized", .{});
    }

    pub fn deinit() void {
        for (books.items) |*book| {
            book.deinit(allocator);
        }
        books.deinit(allocator);
        std.log.info("[catalog] Catalog module cleaned up", .{});
    }

    /// 图书实体
    pub const Book = struct {
        id: u64,
        isbn: []const u8,
        title: []const u8,
        author: []const u8,
        publisher: []const u8,
        price: f64,
        category: Category,
        description: []const u8,
        tags: std.ArrayList([]const u8),
        created_at: i64,
        updated_at: i64,

        pub const Category = enum {
            fiction,
            non_fiction,
            technology,
            science,
            history,
            art,
            business,
            education,
            other,

            pub fn toString(self: Category) []const u8 {
                return switch (self) {
                    .fiction => "fiction",
                    .non_fiction => "non-fiction",
                    .technology => "technology",
                    .science => "science",
                    .history => "history",
                    .art => "art",
                    .business => "business",
                    .education => "education",
                    .other => "other",
                };
            }

            pub fn fromString(s: []const u8) Category {
                if (std.mem.eql(u8, s, "fiction")) return .fiction;
                if (std.mem.eql(u8, s, "non-fiction")) return .non_fiction;
                if (std.mem.eql(u8, s, "technology")) return .technology;
                if (std.mem.eql(u8, s, "science")) return .science;
                if (std.mem.eql(u8, s, "history")) return .history;
                if (std.mem.eql(u8, s, "art")) return .art;
                if (std.mem.eql(u8, s, "business")) return .business;
                if (std.mem.eql(u8, s, "education")) return .education;
                return .other;
            }
        };

        pub fn deinit(self: *Book, alloc: std.mem.Allocator) void {
            alloc.free(self.isbn);
            alloc.free(self.title);
            alloc.free(self.author);
            alloc.free(self.publisher);
            alloc.free(self.description);
            for (self.tags.items) |tag| {
                alloc.free(tag);
            }
            self.tags.deinit(allocator);
        }
    };

    /// 创建图书
    pub fn createBook(request: CreateBookRequest) !Book {
        const now = std.time.timestamp();

        var book = Book{
            .id = book_id_counter,
            .isbn = try allocator.dupe(u8, request.isbn),
            .title = try allocator.dupe(u8, request.title),
            .author = try allocator.dupe(u8, request.author),
            .publisher = try allocator.dupe(u8, request.publisher),
            .price = request.price,
            .category = request.category,
            .description = try allocator.dupe(u8, request.description),
            .tags = std.ArrayList([]const u8){},
            .created_at = now,
            .updated_at = now,
        };

        // Copy tags
        for (request.tags) |tag| {
            try book.tags.append(allocator, try allocator.dupe(u8, tag));
        }

        book_id_counter += 1;
        try books.append(allocator, book);

        std.log.info("[catalog] Created book: {s} (id={d})", .{ book.title, book.id });

        return book;
    }

    /// 创建图书请求
    pub const CreateBookRequest = struct {
        isbn: []const u8,
        title: []const u8,
        author: []const u8,
        publisher: []const u8,
        price: f64,
        category: Book.Category,
        description: []const u8,
        tags: []const []const u8 = &.{},
    };

    /// 获取所有图书
    pub fn getAllBooks() []Book {
        return books.items;
    }

    /// 根据 ID 获取图书
    pub fn getBookById(id: u64) ?*Book {
        for (books.items) |*book| {
            if (book.id == id) {
                return book;
            }
        }
        return null;
    }

    /// 更新图书
    pub fn updateBook(id: u64, request: UpdateBookRequest) !?Book {
        var book = getBookById(id) orelse return null;

        const now = std.time.timestamp();

        if (request.title) |title| {
            allocator.free(book.title);
            book.title = try allocator.dupe(u8, title);
        }

        if (request.author) |author| {
            allocator.free(book.author);
            book.author = try allocator.dupe(u8, author);
        }

        if (request.price) |price| {
            book.price = price;
        }

        if (request.category) |category| {
            book.category = category;
        }

        if (request.description) |desc| {
            allocator.free(book.description);
            book.description = try allocator.dupe(u8, desc);
        }

        book.updated_at = now;

        std.log.info("[catalog] Updated book: {s} (id={d})", .{ book.title, book.id });

        return book.*;
    }

    /// 更新图书请求
    pub const UpdateBookRequest = struct {
        title: ?[]const u8 = null,
        author: ?[]const u8 = null,
        price: ?f64 = null,
        category: ?Book.Category = null,
        description: ?[]const u8 = null,
    };

    /// 删除图书
    pub fn deleteBook(id: u64) !bool {
        for (books.items, 0..) |*book, index| {
            if (book.id == id) {
                std.log.info("[catalog] Deleted book: {s} (id={d})", .{ book.title, book.id });
                book.deinit(allocator);
                _ = books.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    /// 搜索图书
    pub fn searchBooks(query: SearchQuery) ![]Book {
        var results = std.ArrayList(Book){};

        for (books.items) |book| {
            var matches = false;

            // Keyword search
            if (query.keyword) |keyword| {
                if (std.mem.indexOf(u8, book.title, keyword) != null or
                    std.mem.indexOf(u8, book.author, keyword) != null)
                {
                    matches = true;
                }
            }

            // Category filter
            if (query.category) |cat| {
                if (book.category == cat) {
                    matches = true;
                } else if (query.keyword == null) {
                    matches = false;
                }
            }

            // Price range filter
            if (query.min_price) |min| {
                if (book.price < min) matches = false;
            }

            if (query.max_price) |max| {
                if (book.price > max) matches = false;
            }

            if (matches) {
                try results.append(book);
            }
        }

        return results.toOwnedSlice();
    }

    /// 搜索查询
    pub const SearchQuery = struct {
        keyword: ?[]const u8 = null,
        category: ?Book.Category = null,
        min_price: ?f64 = null,
        max_price: ?f64 = null,
    };

    /// 获取分类统计
    pub fn getCategoryStats() !CategoryStats {
        var stats = CategoryStats{};

        for (books.items) |book| {
            stats.total_books += 1;
            stats.total_value += book.price;

            switch (book.category) {
                .fiction => stats.fiction_count += 1,
                .technology => stats.technology_count += 1,
                .science => stats.science_count += 1,
                .history => stats.history_count += 1,
                .business => stats.business_count += 1,
                else => stats.other_count += 1,
            }
        }

        return stats;
    }

    /// 分类统计
    pub const CategoryStats = struct {
        total_books: u32 = 0,
        total_value: f64 = 0,
        fiction_count: u32 = 0,
        technology_count: u32 = 0,
        science_count: u32 = 0,
        history_count: u32 = 0,
        business_count: u32 = 0,
        other_count: u32 = 0,
    };

    /// 添加示例数据
    pub fn seedData() !void {
        const sample_books = [_]CreateBookRequest{
            .{
                .isbn = "978-0-13-110362-7",
                .title = "The C Programming Language",
                .author = "Brian Kernighan, Dennis Ritchie",
                .publisher = "Prentice Hall",
                .price = 59.99,
                .category = .technology,
                .description = "The classic book on C programming",
                .tags = &.{ "programming", "c", "classic" },
            },
            .{
                .isbn = "978-0-201-63361-0",
                .title = "Design Patterns",
                .author = "Gang of Four",
                .publisher = "Addison-Wesley",
                .price = 54.99,
                .category = .technology,
                .description = "Elements of Reusable Object-Oriented Software",
                .tags = &.{ "patterns", "oop", "design" },
            },
            .{
                .isbn = "978-0-13-468599-1",
                .title = "Clean Code",
                .author = "Robert C. Martin",
                .publisher = "Prentice Hall",
                .price = 44.99,
                .category = .technology,
                .description = "A Handbook of Agile Software Craftsmanship",
                .tags = &.{ "clean-code", "agile", "best-practices" },
            },
            .{
                .isbn = "978-0-452-28423-4",
                .title = "1984",
                .author = "George Orwell",
                .publisher = "Penguin",
                .price = 14.99,
                .category = .fiction,
                .description = "Dystopian social science fiction novel",
                .tags = &.{ "dystopia", "classic", "political" },
            },
            .{
                .isbn = "978-0-7432-7356-5",
                .title = "The Da Vinci Code",
                .author = "Dan Brown",
                .publisher = "Doubleday",
                .price = 16.99,
                .category = .fiction,
                .description = "Mystery thriller novel",
                .tags = &.{ "thriller", "mystery", "bestseller" },
            },
        };

        for (sample_books) |book| {
            _ = try createBook(book);
        }

        std.log.info("[catalog] Seeded {d} sample books", .{sample_books.len});
    }
};

test "Catalog module" {
    try CatalogModule.init();
    defer CatalogModule.deinit();

    // Create a book
    const book = try CatalogModule.createBook(.{
        .isbn = "978-0-13-110362-7",
        .title = "The C Programming Language",
        .author = "K&R",
        .publisher = "Prentice Hall",
        .price = 59.99,
        .category = .technology,
        .description = "The classic C book",
    });

    try std.testing.expectEqualStrings("The C Programming Language", book.title);

    // Get all books
    const all_books = CatalogModule.getAllBooks();
    try std.testing.expectEqual(@as(usize, 1), all_books.len);

    // Search
    const results = try CatalogModule.searchBooks(.{
        .keyword = "C",
        .category = .technology,
    });
    try std.testing.expectEqual(@as(usize, 1), results.len);

    // Update
    const updated = try CatalogModule.updateBook(book.id, .{
        .price = 49.99,
    });
    try std.testing.expect(updated != null);
    try std.testing.expectApproxEqAbs(@as(f64, 49.99), updated.?.price, 0.01);

    // Delete
    const deleted = try CatalogModule.deleteBook(book.id);
    try std.testing.expect(deleted);
}
