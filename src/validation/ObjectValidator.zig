const std = @import("std");

/// Validates DTO fields, accumulating one error per failed rule.
pub const Validator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    errors: std.ArrayList(ValidationError),

    pub const ValidationError = struct {
        field: []const u8,
        message: []const u8,
        code: []const u8,
    };

    pub const ValidationResult = struct {
        valid: bool,
        errors: []ValidationError,

        pub fn isValid(self: ValidationResult) bool {
            return self.valid;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(ValidationError).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.field);
            self.allocator.free(err.message);
            self.allocator.free(err.code);
        }
        self.errors.deinit(self.allocator);
        self.* = undefined;
    }

    /// Field is present and non-empty.
    pub fn required(self: *Self, field_name: []const u8, value: ?[]const u8) !void {
        if (value == null or value.?.len == 0) {
            try self.addError(field_name, "Field is required", "REQUIRED");
        }
    }

    /// Fails when `value` is shorter than `min` characters.
    pub fn minLength(self: *Self, field_name: []const u8, value: []const u8, min: usize) !void {
        if (value.len < min) {
            const msg = try std.fmt.allocPrint(self.allocator, "Minimum length is {d}, got {d}", .{ min, value.len });
            defer self.allocator.free(msg);
            try self.addError(field_name, msg, "MIN_LENGTH");
        }
    }

    /// Fails when `value` is longer than `max` characters.
    pub fn maxLength(self: *Self, field_name: []const u8, value: []const u8, max: usize) !void {
        if (value.len > max) {
            const msg = try std.fmt.allocPrint(self.allocator, "Maximum length is {d}, got {d}", .{ max, value.len });
            defer self.allocator.free(msg);
            try self.addError(field_name, msg, "MAX_LENGTH");
        }
    }

    /// Fails when the integer `value` falls outside [`min`, `max`].
    pub fn range(self: *Self, field_name: []const u8, value: i64, min: i64, max: i64) !void {
        if (value < min or value > max) {
            const msg = try std.fmt.allocPrint(self.allocator, "Value must be between {d} and {d}", .{ min, max });
            defer self.allocator.free(msg);
            try self.addError(field_name, msg, "RANGE");
        }
    }

    /// Field looks like an email address (empty values pass; pair with `required`).
    pub fn email(self: *Self, field_name: []const u8, value: []const u8) !void {
        if (value.len == 0) return;

        // Minimal structural check: an '@' plus a '.' after it
        var has_at = false;
        var has_dot = false;
        for (value) |c| {
            if (c == '@') has_at = true;
            if (c == '.' and has_at) has_dot = true;
        }

        if (!has_at or !has_dot) {
            try self.addError(field_name, "Invalid email format", "EMAIL");
        }
    }

    /// Field matches `regex_pattern`.
    pub fn pattern(self: *Self, field_name: []const u8, value: []const u8, regex_pattern: []const u8) !void {
        // Only the `.*\d.*` pattern is interpreted: require one digit
        const requires_digit = std.mem.eql(u8, regex_pattern, ".*\\d.*");
        if (requires_digit) {
            var has_digit = false;
            for (value) |c| {
                if (std.ascii.isDigit(c)) {
                    has_digit = true;
                    break;
                }
            }
            if (!has_digit) {
                const err_msg = try std.fmt.allocPrint(self.allocator, "Field '{s}' must contain at least one digit", .{field_name});
                defer self.allocator.free(err_msg);
                try self.addError(field_name, "Must contain at least one digit", "PATTERN");
            }
        }
    }

    /// Fails unless `value` matches one of `allowed_values`.
    pub fn enumValue(self: *Self, field_name: []const u8, value: []const u8, allowed_values: []const []const u8) !void {
        for (allowed_values) |allowed| {
            if (std.mem.eql(u8, value, allowed)) return;
        }
        try self.addError(field_name, "Invalid enum value", "ENUM");
    }

    /// Fails when `value` is empty.
    pub fn notEmpty(self: *Self, field_name: []const u8, value: []const u8) !void {
        if (value.len == 0) {
            try self.addError(field_name, "Array must not be empty", "NOT_EMPTY");
        }
    }

    /// Appends one error, duplicating all three strings into the allocator.
    fn addError(self: *Self, field: []const u8, message: []const u8, code: []const u8) !void {
        const field_copy = try self.allocator.dupe(u8, field);
        const msg_copy = try self.allocator.dupe(u8, message);
        const code_copy = try self.allocator.dupe(u8, code);

        try self.errors.append(self.allocator, .{
            .field = field_copy,
            .message = msg_copy,
            .code = code_copy,
        });
    }

    /// Returns the collected result; valid when no error was recorded.
    pub fn validate(self: *Self) ValidationResult {
        return .{
            .valid = self.errors.items.len == 0,
            .errors = self.errors.items,
        };
    }

    /// Runs the built-in rules over the fields of a reflected struct.
    pub fn validateObject(self: *Self, comptime T: type, obj: T) !ValidationResult {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            const field_name = field.name;
            const field_value = @field(obj, field_name);

            // Apply the rules that match the field type
            switch (@typeInfo(field.type)) {
                .Optional => {
                    if (field_value == null) {
                        try self.required(field_name, null);
                    }
                },
                .Pointer => |ptr| {
                    if (ptr.size == .Slice and ptr.child == u8) {
                        // Plain string slice: require 1..255 bytes
                        try self.required(field_name, field_value);
                        try self.minLength(field_name, field_value, 1);
                        try self.maxLength(field_name, field_value, 255);
                    }
                },
                .Int => {
                    try self.range(field_name, field_value, 0, std.math.maxInt(i64));
                },
                else => {},
            }
        }

        return self.validate();
    }
};

// Tests: DTO validation
test "Validator - basic validation" {
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    try validator.required("username", "john");
    try validator.minLength("password", "secret123", 6);
    try validator.maxLength("email", "john@example.com", 100);
    try validator.email("email", "john@example.com");

    const result = validator.validate();

    try std.testing.expect(result.isValid());
}

test "Validator - validation errors" {
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    try validator.required("username", null);
    try validator.minLength("password", "123", 6);
    try validator.email("email", "invalid-email");

    const result = validator.validate();

    try std.testing.expect(!result.isValid());
    try std.testing.expectEqual(@as(usize, 3), result.errors.len);
}
