const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Utf8Iterator = std.unicode.Utf8Iterator;
const print = std.debug.print;

const Lexer = @import("lexer.zig").Lexer;
const Token = @import("lexer.zig").Token;
const TokenTag = @import("lexer.zig").TokenTag;

const Error = error{
    IllegalToken,
    NoCompleteSymlink,
};

const State = enum {
    path,
    target,
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

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.target);
        allocator.free(self.path);
    }

    pub fn clone(self: @This(), allocator: Allocator) !@This() {
        return @This().init(allocator, self.target, self.path);
    }

    pub fn eql(self: @This(), other: @This()) bool {
        return std.mem.eql(u8, self.target, other.target) and std.mem.eql(u8, self.path, other.path);
    }

    pub fn format(
        self: @This(),
        writer: anytype,
    ) !void {
        _ = try writer.print("{s} -> {s}", .{ self.path, self.target });
    }
};

pub const Parser = struct {
    path: ?[]const u8 = null,
    state: State = .path,
    lexer: *Lexer,
    text: ArrayList(u8),
    token: ?Token = null,
    // XXX: WWWWHHHHYYYY doesn't null check work for self.token?????????
    deinitToken: bool = false,
    envLookup: *const EnvLookup,
    allocator: Allocator,

    const EnvLookup = fn ([]const u8) ?[]const u8;

    pub fn init(allocator: Allocator, lexer: *Lexer, env_lookup: *const EnvLookup) !@This() {
        return @This(){
            .lexer = lexer,
            .text = .empty,
            .envLookup = env_lookup,
            .allocator = allocator,
            .token = try lexer.next(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.text.deinit(self.allocator);
        // print("Parser.deinit free self.token {any}\n", .{self.token});
        // print("Parser.deinit free self.deinitToken {any}\n", .{self.deinitToken});

        // XXX: How can I use self.token nullable to check if we need to deinit?
        // if (self.token) |token| token.deinit(self.allocator);
        if (self.deinitToken) self.token.?.deinit(self.allocator);

        // print("Parser.deinit free self.path {any}\n", .{self.path});
        if (self.path) |path| self.allocator.free(path);
    }

    fn makeText(self: *@This()) ![]const u8 {
        const text = self.allocator.dupe(u8, self.text.items);
        self.text.clearAndFree(self.allocator);
        return text;
    }

    fn noText(self: *@This()) bool {
        return std.mem.eql(u8, "", std.mem.trim(u8, self.text.items, " "));
    }

    fn skip(self: *@This()) !void {
        if (self.token) |token| token.deinit(self.allocator);
        self.token = try self.lexer.next(self.allocator);
        self.deinitToken = self.token != null;
        // print("Parser.skip AAAAHHH {any}\n", .{self.token});
        // print("Parser.skip deinitToken {any}\n", .{self.deinitToken});
    }

    fn consume(self: *@This()) !void {
        if (self.token) |token| {
            try self.text.appendSlice(self.allocator, token.text);
        }
        try self.skip();
    }

    fn consumeEnv(self: *@This()) !void {
        if (self.token) |token| {
            try self.appendEnvLookup(token.text);
        }
        try self.skip();
    }

    fn appendEnvLookup(self: *@This(), env: []const u8) !void {
        const env_text = self.envLookup(env).?;
        try self.text.appendSlice(self.allocator, env_text);
    }

    fn makePath(self: *@This()) !void {
        self.path = try self.makeText();
        self.state = .target;
    }

    fn makeLink(self: *@This(), allocator: Allocator) !?Link {
        if (self.state == .path or self.path == null or self.noText())
            return null;

        self.state = .path;
        if (self.path) |path| {
            const target = try self.makeText();
            defer {
                self.allocator.free(target);
                self.allocator.free(path);
            }
            self.path = null;
            return try Link.init(allocator, target, path);
        }
        return null;
    }

    pub fn next(self: *@This(), allocator: Allocator) !?Link {
        while (self.token) |token| {
            // print("{s}: token={}\n", .{ @tagName(self.state), token });

            try switch (token.tag) {
                .path => self.consume(),
                .env => self.consumeEnv(),
                .home => {
                    try self.appendEnvLookup("HOME");
                    try self.skip();
                },
                .divider => switch (self.state) {
                    .path => {
                        try self.makePath();
                        try self.skip();
                    },
                    .target => try self.consume(), //return Error.IllegalToken,
                },
                .newline => switch (self.state) {
                    .path => if (self.noText())
                        self.skip()
                    else
                        return Error.IllegalToken,
                    .target => {
                        try self.skip();
                        return self.makeLink(allocator);
                    },
                },
                .comment => switch (self.state) {
                    .path => if (self.noText())
                        self.skip()
                    else
                        return Error.IllegalToken,
                    .target => self.skip(),
                },
            };
        }
        return self.makeLink(allocator);
    }
};

test "parse simple manifest" {
    const allocator = std.testing.allocator;
    const matrix = [_]struct { []const u8, []const Link }{
        .{
            \\ # comment 1
            \\path0:./lol
            \\# alsdfj
            \\  path1  : trimit # hejhej
            \\path2:/mjau/$HOME/home
            \\
            ,
            &.{
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
            },
        },
        .{
            \\$HOME:./target1
            \\path2:$HOME/target2
            ,
            &.{
                .{
                    .target = "./target1",
                    .path = "_HOME_",
                },
                .{
                    .target = "_HOME_/target2",
                    .path = "path2",
                },
            },
        },
    };

    for (matrix) |row| {
        const manifest = row[0];
        const expect = row[1];

        var lexer = try Lexer.init(allocator, manifest);
        defer lexer.deinit();

        var parser = try Parser.init(allocator, &lexer, TestEnvLookup.lookup);
        defer parser.deinit();

        for (expect) |ex_link| {
            if (try parser.next(allocator)) |link| {
                defer link.deinit(allocator);
                try std.testing.expectEqualStrings(ex_link.target, link.target);
                try std.testing.expectEqualStrings(ex_link.path, link.path);
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
}

test "parse manifest no trailing newline" {
    const allocator = std.testing.allocator;

    const manifest =
        \\ # comment 1
        \\path1:target1
        \\path2:target2
        \\$HOME/path3:$HOME/target3
        \\~/path4:~/target4
        \\path5:target5:end
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
        .{
            .target = "_HOME_/target3",
            .path = "_HOME_/path3",
        },
        .{
            .target = "_HOME_/target4",
            .path = "_HOME_/path4",
        },
        .{
            .target = "target5:end",
            .path = "path5",
        },
    };

    var lexer = try Lexer.init(allocator, manifest);
    defer lexer.deinit();

    var parser = try Parser.init(allocator, &lexer, TestEnvLookup.lookup);
    defer parser.deinit();

    for (matrix) |row| {
        if (try parser.next(allocator)) |link| {
            // print("link={}\n", .{link});
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

const TestEnvLookup = struct {
    pub fn lookup(_: []const u8) ?[]const u8 {
        return "_HOME_";
    }
};

test "parse fail" {
    const allocator = std.testing.allocator;
    const matrix = [_]struct { []const u8, Error }{
        .{
            \\ path1 # comment 1
            \\path2:illegal:
            \\
            ,
            Error.IllegalToken,
        },
    };

    for (matrix) |row| {
        const manifest = row[0];
        const expect = row[1];

        var lexer = try Lexer.init(allocator, manifest);
        defer lexer.deinit();

        var parser = try Parser.init(allocator, &lexer, TestEnvLookup.lookup);
        defer parser.deinit();

        while (true) {
            if (parser.next(allocator)) |link| {
                if (link) |_| {
                    try std.testing.expect(false);
                } else {
                    break;
                }
            } else |err| {
                try std.testing.expectEqual(expect, err);
                break;
            }
        }
    }
}
