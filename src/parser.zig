const std = @import("std");
const tknzr = @import("tokenizer.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Utf8Iterator = std.unicode.Utf8Iterator;

const Token = tknzr.Token;
const Tokenizer = tknzr.Tokenizer;

const Error = error{
    NotAllowedOrder,
};

const State = enum {
    start,
    symlink_begin,
    symlink_end,
};

const PathState = enum {
    env,
    path,
};

pub const Link = struct {
    target: []const u8,
    path: []const u8,

    pub fn init(allocator: Allocator, target: []const u8, path: []const u8) !@This() {
        return .{
            .target = try allocator.dupe(u8, std.mem.trim(u8, target, " ")),
            .path = try allocator.dupe(u8, std.mem.trim(u8, path, " ")),
        };
    }

    pub fn clone(self: @This(), allocator: Allocator) !@This() {
        return @This().init(allocator, self.target, self.path);
    }

    pub fn eql(self: @This(), other: @This()) bool {
        return std.mem.eql(u8, self.target, other.target) and std.mem.eql(u8, self.path, other.path);
    }

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = try writer.print("{s} -> {s}", .{ self.path, self.target });
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.target);
        allocator.free(self.path);
    }
};

pub const Parser = struct {
    path: ArrayList(u8),
    target: ArrayList(u8),
    tokenizer: Tokenizer,
    state: State = .start,
    envLookup: *const EnvLookup,

    const EnvLookup = fn ([]const u8) ?[]const u8;

    pub fn init(allocator: Allocator, tokenizer: Tokenizer, env_lookup: *const EnvLookup) @This() {
        return .{
            .tokenizer = tokenizer,
            .path = ArrayList(u8).init(allocator),
            .target = ArrayList(u8).init(allocator),
            .envLookup = env_lookup,
        };
    }

    pub fn deinit(self: @This()) void {
        self.path.deinit();
        self.target.deinit();
    }

    fn makePath(self: *@This(), allocator: Allocator) ![]const u8 {
        const text = try allocator.dupe(u8, self.path.items);
        self.path.clearAndFree();
        return text;
    }

    fn makeTarget(self: *@This(), allocator: Allocator) ![]const u8 {
        const text = try allocator.dupe(u8, self.target.items);
        self.target.clearAndFree();
        return text;
    }

    fn makeLink(self: *@This(), allocator: Allocator) !?Link {

        if (self.target.items.len == 0) return null;
        const path = try self.makePath(allocator);
        defer allocator.free(path);
        const target = try self.makeTarget(allocator);
        defer allocator.free(target);
        return try Link.init(allocator, target, path);
    }

    pub fn next(self: *@This(), allocator: Allocator) !?Link {
        var link: ?Link = null;
        var env_text: ?[]const u8 = null;
        // defer if (env_text) |x| { allocator.free(x); };

        while (link == null) {
            if (try self.tokenizer.next(allocator)) |token| {
                defer token.deinit(allocator);
                const tag = token.tag;

                switch (self.state) {
                    .start, .symlink_end => switch (tag) {
                        .path => {
                            try self.path.appendSlice(token.text);
                        },
                        .divider => {
                            self.state = .symlink_begin;
                        },
                        .path_env => {
                            env_text = self.envLookup(token.text);
                            try self.path.appendSlice(env_text.?);
                        },
                        .target, .target_env => return Error.NotAllowedOrder,
                        else => {},
                    },
                    .symlink_begin => switch (tag) {
                        .target => {
                            try self.target.appendSlice(token.text);
                        },
                        .target_env => {
                            env_text = self.envLookup(token.text);
                            try self.target.appendSlice(env_text.?);
                        },
                        .newline => {
                            link = try self.makeLink(allocator);
                            self.state = .symlink_end;
                        },
                        .path, .path_env => return Error.NotAllowedOrder,
                        else => {},
                    },
                }
            } else {
                link = try self.makeLink(allocator);
                break;
            }
        }
        return link;
    }
};

test "parse simple manifest" {
    const allocator = std.testing.allocator;

    const manifest =
        \\ # comment 1
        \\path0:./lol
        \\# alsdfj
        \\  path1  : trimit # hejhej
        \\path2:/mjau/$HOME/home
        \\
    ;

    const matrix = [_]Link{
        .{
            .target = "./lol",
            .path = "path0",
        },
        .{
            .target = "trimit",
            .path = "path1",
        },
        .{
            .target = "/mjau/_HOME_/home",
            .path = "path2",
        },
    };

    const tokenizer = try Tokenizer.init(allocator, manifest);
    defer tokenizer.deinit();

    const EnvLookup = struct {
        pub fn lookup(_: []const u8) ?[]const u8 {
            return "_HOME_";
        }
    };

    var parser = Parser.init(allocator, tokenizer, EnvLookup.lookup);
    defer parser.deinit();

    for (matrix) |row| {
        if (try parser.next(allocator)) |link| {
            defer link.deinit(allocator);
            try std.testing.expectEqualStrings(row.target, link.target);
            try std.testing.expectEqualStrings(row.path, link.path);
        } else {
            // Too few lines in manifest
            try std.testing.expect(false);
        }
    }

    if (try parser.next(allocator)) |link| {
        defer link.deinit(allocator);
        // Lines in manifest untested against matrix
        try std.testing.expect(false);
    }
}

test "parse manifest no trailing newline" {
    const allocator = std.testing.allocator;

    const manifest =
        \\ # comment 1
        \\path1:target1
        \\path2:target2
    ;

    const matrix = [_]Link{
        .{
            .target = "target1",
            .path = "path1",
        },
        .{
            .target = "target2",
            .path = "path2",
        },
    };

    const tokenizer = try Tokenizer.init(allocator, manifest);
    defer tokenizer.deinit();

    const EnvLookup = struct {
        pub fn lookup(_: []const u8) ?[]const u8 {
            return "_HOME_";
        }
    };

    var parser = Parser.init(allocator, tokenizer, EnvLookup.lookup);
    defer parser.deinit();

    for (matrix) |row| {
        if (try parser.next(allocator)) |link| {
            defer link.deinit(allocator);
            try std.testing.expectEqualStrings(row.target, link.target);
            try std.testing.expectEqualStrings(row.path, link.path);
        } else {
            // Didn't parse enough links from manifest
            try std.testing.expect(false);
        }
    }

    if (try parser.next(allocator)) |link| {
        defer link.deinit(allocator);
        // Lines in manifest untested against matrix
        try std.testing.expect(false);
    }
}
