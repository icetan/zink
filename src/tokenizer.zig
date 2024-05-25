const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Utf8Iterator = std.unicode.Utf8Iterator;

const Error = error{
    NotAllowedAfterDivider,
};

pub const TokenTag = enum {
    start,
    newline,
    pre_comment,
    comment,
    path,
    pre_path_env,
    path_env,
    divider,
    target,
    pre_target_env,
    target_env,
};

pub const Token = struct {
    tag: TokenTag,
    text: []const u8,

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = try writer.print("{s}({s})", .{ @tagName(self.tag), self.text });
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.text);
    }
};

pub const Tokenizer = struct {
    reader: Utf8Iterator,
    next_tag: TokenTag,
    text: ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, manifest: []const u8) !@This() {
        const reader = (try std.unicode.Utf8View.init(manifest)).iterator();
        const text = ArrayList(u8).init(allocator);
        return .{
            .allocator = allocator,
            .reader = reader,
            .next_tag = .start,
            .text = text,
        };
    }

    pub fn deinit(self: @This()) void {
        self.text.deinit();
    }

    fn consume(self: *@This()) !void {
        if (self.reader.nextCodepointSlice()) |cp| {
            try self.text.appendSlice(cp);
        }
    }

    fn makeToken(self: *@This(), tag: TokenTag, allocator: Allocator) !Token {
        const text = try allocator.dupe(u8, self.text.items);
        self.text.clearAndFree();
        return .{ .tag = tag, .text = text };
    }

    pub fn next(self: *@This(), allocator: Allocator) !?Token {
        var tag: TokenTag = undefined;
        while (true) {
            tag = self.next_tag;
            if (tag != .start) try self.consume();

            const peek = self.reader.peek(1);
            if (peek.len == 0) {
                if (self.text.items.len > 0) {
                    return try self.makeToken(tag, allocator);
                }
                break;
            }

            const cp = peek[0];
            self.next_tag = switch (self.next_tag) {
                .start, .newline => switch (cp) {
                    '\n', ' ' => .newline,
                    '#' => .pre_comment,
                    '$' => .pre_path_env,
                    else => .path,
                },
                .pre_comment => switch (cp) {
                    '\n' => .newline,
                    else => .comment,
                },
                .comment => switch (cp) {
                    '\n' => .newline,
                    else => .comment,
                },
                .path => switch (cp) {
                    '\n', '#' => return Error.NotAllowedAfterDivider,
                    '$' => .pre_path_env,
                    ':' => .divider,
                    else => .path,
                },
                .pre_path_env => switch (cp) {
                    '\n', ':', '#', '/', ' ', ',', '.', '-' => return Error.NotAllowedAfterDivider,
                    else => .path_env,
                },
                .path_env => switch (cp) {
                    '\n', '#' => return Error.NotAllowedAfterDivider,
                    '/', ' ', ',', '.', '-' => .path,
                    ':' => .divider,
                    else => .path_env,
                },
                .divider => switch (cp) {
                    '\n', ':', '#' => return Error.NotAllowedAfterDivider,
                    else => .target,
                },
                .target => switch (cp) {
                    '\n' => .newline,
                    '#' => .pre_comment,
                    '$' => .pre_target_env,
                    else => .target,
                },
                .pre_target_env => switch (cp) {
                    '\n', ':', '#', '/', ' ', ',', '.', '-' => return Error.NotAllowedAfterDivider,
                    else => .target_env,
                },
                .target_env => switch (cp) {
                    '\n' => .newline,
                    '#' => .pre_comment,
                    '/', ' ', ',', '.', '-', ':' => .target,
                    else => .target_env,
                },
            };

            if (tag != .start and self.next_tag != tag) {
                const token = try self.makeToken(tag, allocator);
                // std.debug.print("Tokanizer.next() returns: {}\n", .{token});
                return token;
            }
        }
        return null;
    }
};

test "tokenize simple manifest" {
    const allocator = std.testing.allocator;

    const manifest =
        \\path1:target1
        \\path2/$ENV1: target2
        \\# comment1:$NOTENV
        \\   path3 $ENV2 :target3  # comment2
    ;

    const matrix = [_]struct { TokenTag, []const u8 }{
        .{ .path, "path1" },
        .{ .divider, ":" },
        .{ .target, "target1" },
        .{ .newline, "\n" },
        .{ .path, "path2/" },
        .{ .pre_path_env, "$" },
        .{ .path_env, "ENV1" },
        .{ .divider, ":" },
        .{ .target, " target2" },
        .{ .newline, "\n" },
        .{ .pre_comment, "#" },
        .{ .comment, " comment1:$NOTENV" },
        .{ .newline, "\n   " },
        .{ .path, "path3 " },
        .{ .pre_path_env, "$" },
        .{ .path_env, "ENV2" },
        .{ .path, " " },
        .{ .divider, ":" },
        .{ .target, "target3  " },
        .{ .pre_comment, "#" },
        .{ .comment, " comment2" },
    };

    var tokenizer = try Tokenizer.init(allocator, manifest);
    defer tokenizer.deinit();

    for (matrix) |row| {
        if (try tokenizer.next(allocator)) |token| {
            defer token.deinit(allocator);
            std.debug.print("token={any}\n", .{token});
            try std.testing.expectEqual(
                row[0],
                token.tag,
            );
            try std.testing.expectEqualStrings(row[1], token.text);
        } else {
            try std.testing.expect(false);
        }
    }

    if (try tokenizer.next(allocator)) |token| {
        defer token.deinit(allocator);
        try std.testing.expect(false);
    }
}

test "tokanize other manifest" {
    const allocator = std.testing.allocator;

    const manifest =
        \\ # comment 1
        \\path0:./lol
        \\# alsdfj
        \\  path1  : trimit # hejhej
        \\path2:/mjau/$HOME/home
        \\$HOME/path3:../target3
        \\
    ;

    const matrix = [_]struct { TokenTag, []const u8 }{
        .{ .newline, " " },
        .{ .pre_comment, "#" },
        .{ .comment, " comment 1" },
        .{ .newline, "\n" },
        .{ .path, "path0" },
        .{ .divider, ":" },
        .{ .target, "./lol" },
        .{ .newline, "\n" },
        .{ .pre_comment, "#" },
        .{ .comment, " alsdfj" },
        .{ .newline, "\n  " },
        .{ .path, "path1  " },
        .{ .divider, ":" },
        .{ .target, " trimit " },
        .{ .pre_comment, "#" },
        .{ .comment, " hejhej" },
        .{ .newline, "\n" },
        .{ .path, "path2" },
        .{ .divider, ":" },
        .{ .target, "/mjau/" },
        .{ .pre_target_env, "$" },
        .{ .target_env, "HOME" },
        .{ .target, "/home" },
        .{ .newline, "\n" },
        .{ .pre_path_env, "$" },
        .{ .path_env, "HOME" },
        .{ .path, "/path3" },
        .{ .divider, ":" },
        .{ .target, "../target3" },
        .{ .newline, "\n" },
    };

    var tokenizer = try Tokenizer.init(allocator, manifest);
    defer tokenizer.deinit();

    for (matrix, 0..) |row, i| {
        if (try tokenizer.next(allocator)) |token| {
            defer token.deinit(allocator);
            std.debug.print("token({d})={any}\n", .{ i, token });
            try std.testing.expectEqual(
                row[0],
                token.tag,
            );
            try std.testing.expectEqualStrings(row[1], token.text);
        } else {
            try std.testing.expect(false);
        }
    }

    if (try tokenizer.next(allocator)) |token| {
        defer token.deinit(allocator);
        try std.testing.expect(false);
    }
}
