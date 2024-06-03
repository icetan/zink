const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Utf8Iterator = std.unicode.Utf8Iterator;
const print = std.debug.print;

const Error = error{ NotAllowedAfterDivider, IllegalCharacter };

pub const TokenTag = enum {
    newline,
    comment,
    path,
    divider,
    env,
    home,
};

pub const Token = struct {
    tag: TokenTag,
    text: []const u8,

    pub fn init(allocator: Allocator, tag: TokenTag, text: []const u8) !@This() {
        return .{
            .tag = tag,
            .text = try allocator.dupe(u8, text),
        };
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        // print("Token.deinit {}\n", .{self});
        allocator.free(self.text);
    }

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = try writer.print("{s}({s})", .{ @tagName(self.tag), self.text });
    }
};

pub const Lexer = struct {
    reader: Utf8Iterator,
    codepoint: ?[]const u8,
    text: ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, manifest: []const u8) !@This() {
        var reader = (try std.unicode.Utf8View.init(manifest)).iterator();
        const codepoint = reader.nextCodepointSlice();
        const text = ArrayList(u8).init(allocator);
        const self = @This(){
            .allocator = allocator,
            .reader = reader,
            .text = text,
            .codepoint = codepoint,
        };
        return self;
    }

    pub fn deinit(self: @This()) void {
        self.text.deinit();
    }

    fn consume(self: *@This()) !void {
        if (self.codepoint) |cp| {
            try self.text.appendSlice(cp);
            // print("consumed cp == {s}\n", .{cp});
        }
        // self.codepoint = self.reader.nextCodepointSlice();
        self.skip();
        // if (self.codepoint) |cp| {
            // print("now on cp == {s}\n", .{cp});
        // }
    }

    fn skip(self: *@This()) void {
        self.codepoint = self.reader.nextCodepointSlice();
    }

    fn char(self: *@This()) ?u8 {
        return if (self.codepoint) |cp| if (cp.len > 0) cp[0] else null else null;
    }

    fn lastChar(self: *@This()) ?u8 {
        if (self.text.items.len > 0) {
            return self.text.items[self.text.items.len - 1];
        }
        return null;
    }

    fn makeToken(self: *@This(), allocator: Allocator, tag: TokenTag) !Token {
        const token = try Token.init(allocator, tag, self.text.items);
        self.text.clearAndFree();
        // print("makeToken {s} == {s}\n", .{@tagName(tag), text});
        return token;
    }

    fn makeCharToken(self: *@This(), allocator: Allocator, tag: TokenTag) !Token {
        try self.consume();
        // print("makeCharToken {s}\n", .{@tagName(tag)});
        const token = try self.makeToken(allocator, tag);
        return token;
    }

    fn comment(self: *@This(), allocator: Allocator) !Token {
        self.skip();
        while (self.char()) |c| switch (c) {
            '\n' => break,
            else => try self.consume(),
        };
        return self.makeToken(allocator, .comment);
    }

    fn env(self: *@This(), allocator: Allocator) !Token {
        self.skip();
        while (self.char()) |c| switch (c) {
            '0'...'9', 'a'...'z', 'A'...'Z', '_' => try self.consume(),
            else => { break; },
        };
        return self.makeToken(allocator, .env);
    }

    fn path(self: *@This(), allocator: Allocator) !Token {
        while (self.char()) |c| switch (c) {
            '#', '\n', '$', ':' => {
                // print("path break c == {s}\n", .{&[_]u8{c}});
                break;
            },
            '\\' => {
                self.skip();
                try self.consume();
            },
            else => try self.consume(),
        };
        return self.makeToken(allocator, .path);
    }

    pub fn next(self: *@This(), allocator: Allocator) !?Token {
        if (self.char()) |c| {
            // std.debug.print("char == {s}\n", .{&[_]u8{c}});
            return try switch (c) {
                '\n' => self.makeCharToken(allocator, .newline),
                '#' => self.comment(allocator),
                '$' => self.env(allocator),
                '~' => self.makeCharToken(allocator, .home),
                ':' => self.makeCharToken(allocator, .divider),
                else => self.path(allocator),
            };
        }
        return null;
    }
};

test "lex simple manifest" {
    const allocator = std.testing.allocator;

    const manifest =
        \\path1:target1
        \\path2/$ENV2: target2
        \\# comment3:$NOTENV3
        \\   path4 $ENV4 :target4  # comment4
        \\
        \\escape\:divider5:targ\#et5\$NOTENV5
        \\
    ;

    const matrix = [_]struct { TokenTag, []const u8 }{
        .{ .path, "path1" },
        .{ .divider, ":" },
        .{ .path, "target1" },
        .{ .newline, "\n" },
        .{ .path, "path2/" },
        .{ .env, "ENV2" },
        .{ .divider, ":" },
        .{ .path, " target2" },
        .{ .newline, "\n" },
        .{ .comment, " comment3:$NOTENV3" },
        .{ .newline, "\n" },
        .{ .path, "   path4 " },
        .{ .env, "ENV4" },
        .{ .path, " " },
        .{ .divider, ":" },
        .{ .path, "target4  " },
        .{ .comment, " comment4" },
        .{ .newline, "\n" },
        .{ .newline, "\n" },
        .{ .path, "escape:divider5" },
        .{ .divider, ":" },
        .{ .path, "targ#et5$NOTENV5" },
        .{ .newline, "\n" },
    };

    var lexer = try Lexer.init(allocator, manifest);
    defer lexer.deinit();

    for (matrix) |row| {
        if (try lexer.next(allocator)) |token| {
            defer token.deinit(allocator);
            // std.debug.print("({d}) token={any}\n", .{i, token});
            try std.testing.expectEqualStrings(
                @tagName(row[0]),
                @tagName(token.tag),
            );
            try std.testing.expectEqualStrings(row[1], token.text);
        } else {
            // std.debug.print("end\n", .{});
            try std.testing.expect(false);
        }
    }

    if (try lexer.next(allocator)) |token| {
        defer token.deinit(allocator);
        try std.testing.expect(false);
    }
}
