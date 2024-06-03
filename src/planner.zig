const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const Link = @import("parser.zig").Link;
const Parser = @import("parser.zig").Parser;

const Error = error{
    DuplicateManifestEntry,
};

pub const Manifest = struct {
    // links: std.StringArrayHashMap(Link),
    links: std.ArrayList(Link),
    allocator: Allocator,

    pub fn initLinks(allocator: Allocator, ls: []const Link) !@This() {
        // var links = std.StringArrayHashMap(Link).init(allocator);
        var links = std.ArrayList(Link).init(allocator);

        for (ls) |link| {
            const link_ = try link.clone(allocator);
            try links.append(link_);
        }

        return .{
            .links = links,
            .allocator = allocator,
        };
    }

    pub fn init(allocator: Allocator, parser: *Parser) !@This() {
        var links = std.ArrayList(Link).init(allocator);

        while (try parser.next(allocator)) |link| {
            // const link_ = try link.clone(allocator);
            try links.append(link);
        }

        return .{
            .links = links,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.links.items) |link| link.deinit(self.allocator);
        self.links.deinit();
    }

    pub fn append(self: *@This(), link: *Link) !void {
        try self.links.append(try link.clone(self.allocator));
    }

    pub fn appendManifest(self: *@This(), manifest: *Manifest) !void {
        for (manifest.links.items) |link| {
            try self.links.append(try link.clone(self.allocator));
        }
    }

    pub fn save(
        self: @This(),
        writer: anytype,
    ) !void {
        for (self.links.items) |link| {
            _ = try writer.print("{s}:{s}\n", .{ link.path, link.target });
        }
    }

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = try writer.print("{s}", .{@typeName(@This())});
        try writer.writeAll("{\n");

        for (self.links.items) |link| {
            _ = try writer.print("  {}\n", .{link});
        }
        try writer.writeAll("}");
    }

    pub fn eql(self: @This(), other: @This()) bool {
        if (self.links.items.len != other.links.items.len) return false;
        for (self.links.items, 0..) |link, i| {
            const other_link = other.links.items[i];
            if (!link.eql(other_link)) return false;
        }
        return true;
    }
};

pub const Planner = struct {
    noop: []const Link,
    add: []const Link,
    remove: []const Link,
    update: []const UpdateLink,
    allocator: ?Allocator = null,

    pub const UpdateLink = struct {
        target: []const u8,
        path: []const u8,
        new_target: []const u8,

        pub fn init(allocator: Allocator, target: []const u8, path: []const u8, new_target: []const u8) !@This() {
            return .{
                .target = try allocator.dupe(u8, std.mem.trim(u8, target, " ")),
                .path = try allocator.dupe(u8, std.mem.trim(u8, path, " ")),
                .new_target = try allocator.dupe(u8, std.mem.trim(u8, new_target, " ")),
            };
        }

        pub fn toLink(self: @This(), allocator: Allocator) !Link {
            return Link.init(allocator, self.new_target, self.path);
        }

        pub fn eql(self: @This(), other: @This()) bool {
            return std.mem.eql(u8, self.target, other.target) and std.mem.eql(u8, self.path, other.path) and std.mem.eql(u8, self.new_target, other.new_target);
        }

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = try writer.print("{s} -> {s} ({s})", .{ self.path, self.new_target, self.target });
        }

        pub fn deinit(self: @This(), allocator: ?Allocator) void {
            if (allocator) |a| {
                a.free(self.target);
                a.free(self.path);
                a.free(self.new_target);
            }
        }
    };

    pub fn init(allocator: Allocator, current: Manifest, next: Manifest) !@This() {
        // TODO: Add conflicting paths in manifest to Planner struct.
        // var conflict = std.ArrayList([]const u8).init(allocator);
        // defer conflict.deinit();

        var current_map = std.StringHashMap(Link).init(allocator);
        defer current_map.deinit();
        for (current.links.items) |l| try current_map.put(l.path, l);

        var next_map = std.StringHashMap(Link).init(allocator);
        defer next_map.deinit();
        for (next.links.items) |l| try next_map.put(l.path, l);

        var noop = std.ArrayList(Link).init(allocator);
        errdefer noop.deinit();

        var add = std.ArrayList(Link).init(allocator);
        errdefer add.deinit();

        var remove = std.ArrayList(Link).init(allocator);
        errdefer remove.deinit();

        var update = std.ArrayList(UpdateLink).init(allocator);
        errdefer update.deinit();

        var keep = std.StringHashMap(void).init(allocator);
        defer keep.deinit();

        var next_iter = next_map.iterator();
        while (next_iter.next()) |entry| {
            const link = entry.value_ptr.*;
            try keep.put(link.path, {});

            if (current_map.get(link.path)) |cur_link| {
                if (std.mem.eql(u8, cur_link.target, link.target)) {
                    try noop.append(try cur_link.clone(allocator));
                } else {
                    try update.append(try UpdateLink.init(
                        allocator,
                        cur_link.target,
                        cur_link.path,
                        link.target,
                    ));
                }
            } else {
                try add.append(try link.clone(allocator));
            }
        }

        for (current.links.items) |cur_link| {
            if (keep.get(cur_link.path) == null) {
                try remove.append(try cur_link.clone(allocator));
            }
        }

        return .{
            .noop = try noop.toOwnedSlice(),
            .add = try add.toOwnedSlice(),
            .remove = try remove.toOwnedSlice(),
            .update = try update.toOwnedSlice(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: @This()) void {
        if (self.allocator) |allocator| {
            for (self.noop) |link| {
                link.deinit(allocator);
            }
            allocator.free(self.noop);
            for (self.add) |link| {
                link.deinit(allocator);
            }
            allocator.free(self.add);
            for (self.remove) |link| {
                link.deinit(allocator);
            }
            allocator.free(self.remove);
            for (self.update) |uplink| {
                uplink.deinit(allocator);
            }
            allocator.free(self.update);
        }
    }

    pub fn noDiff(self: @This()) bool {
        return self.add.len + self.remove.len + self.update.len == 0;
    }

    pub fn toManifest(self: @This()) !Manifest {
        var links = std.ArrayList(Link).init(self.allocator.?);
        defer links.deinit();
        try links.appendSlice(self.noop);
        for (self.update) |uplink| try links.append(try uplink.toLink(self.allocator.?));
        try links.appendSlice(self.add);
        return Manifest.initLinks(self.allocator.?, links.items);
    }

    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = try writer.print("{s}", .{@typeName(@This())});
        try writer.writeAll("{\n");

        for (self.noop) |link| {
            _ = try writer.print("  = {}\n", .{link});
        }
        for (self.add) |link| {
            _ = try writer.print("  + {}\n", .{link});
        }
        for (self.update) |uplink| {
            _ = try writer.print("  ~ {}\n", .{uplink});
        }
        for (self.remove) |link| {
            _ = try writer.print("  - {}\n", .{link});
        }
        try writer.writeAll("}");
    }

    pub fn eql(self: @This(), other: @This()) bool {
        if (self.noop.len != other.noop.len or self.add.len != other.add.len or self.update.len != other.update.len or self.remove.len != other.remove.len) {
            return false;
        }
        for (self.noop, 0..) |link, i| {
            if (!link.eql(other.noop[i])) {
                print("{} !! == {}\n", .{ link, other.noop[i] });
                return false;
            }
        }
        for (self.add, 0..) |link, i| {
            if (!link.eql(other.add[i])) {
                print("{} !! == {}\n", .{ link, other.add[i] });
                return false;
            }
        }
        for (self.update, 0..) |uplink, i| {
            if (!uplink.eql(other.update[i])) {
                print("{} !! == {}\n", .{ uplink, other.update[i] });
                return false;
            }
        }
        for (self.remove, 0..) |link, i| {
            if (!link.eql(other.remove[i])) {
                print("{} !! == {}\n", .{ link, other.remove[i] });
                return false;
            }
        }
        return true;
    }
};

test "simple planner" {
    const allocator = std.testing.allocator;

    const expect = Planner{
        .noop = &.{.{ .target = "target1", .path = "path1" }},
        .add = &.{.{ .target = "target4", .path = "path4" }},
        .remove = &.{.{ .target = "target2", .path = "path2" }},
        .update = &.{.{
            .target = "target3",
            .path = "path3",
            .new_target = "target5",
        }},
    };

    var current = [_]Link{
        .{ .target = "target1", .path = "path1" },
        .{ .target = "target2", .path = "path2" },
        .{ .target = "target3", .path = "path3" },
    };
    var manifest_current = try Manifest.initLinks(allocator, &current);
    defer manifest_current.deinit();

    var next = [_]Link{
        .{ .target = "target1", .path = "path1" },
        .{ .target = "target5", .path = "path3" },
        .{ .target = "target4", .path = "path4" },
    };
    var manifest_next = try Manifest.initLinks(allocator, &next);
    defer manifest_next.deinit();

    const planner = try Planner.init(
        allocator,
        manifest_current,
        manifest_next,
    );
    defer planner.deinit();

    std.testing.expect(expect.eql(planner)) catch |err| {
        // std.debug.print("{}\n", .{manifest_current});
        // std.debug.print("{}\n", .{manifest_next});
        std.debug.print("expected: {}\ngot: {}\n", .{ expect, planner });
        return err;
    };
}

test "manifest append" {
    const allocator = std.testing.allocator;

    const matrix = [_]struct { m1: Manifest, m2: Manifest, expect: Manifest }{
        .{
            .m1 = try Manifest.initLinks(allocator, &.{
                .{ .target = "target1", .path = "path1" },
            }),
            .m2 = try Manifest.initLinks(allocator, &.{
                .{ .target = "target2", .path = "path2" },
            }),
            .expect = try Manifest.initLinks(allocator, &.{
                .{ .target = "target1", .path = "path1" },
                .{ .target = "target2", .path = "path2" },
            }),
        },
    };

    for (matrix) |row| {
        var m1 = row.m1;
        defer m1.deinit();
        var m2 = row.m2;
        defer m2.deinit();
        var expect = row.expect;
        defer expect.deinit();

        try m1.appendManifest(&m2);

        std.testing.expect(expect.eql(m1)) catch |err| {
            print("expected: {}\ngot: {}\n", .{ expect, m1 });
            return err;
        };
    }
}
