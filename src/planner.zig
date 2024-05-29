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

    pub fn initLinks(allocator: Allocator, ls: []Link) !@This() {
        // var links = std.StringArrayHashMap(Link).init(allocator);
        var links = std.ArrayList(Link).init(allocator);

        for (ls) |link| {
            const link_ = try link.clone(allocator);
            // try links.put(link_.path, link_);

            // const v = try links.getOrPut(link_.path);
            // if (v.found_existing) {
            //     print("Manifest.init error: {}\n", .{link_});
            //     return Error.DuplicateManifestEntry;
            // }
            // v.value_ptr.* = link_;
            try links.append(link_);
        }

        return .{
            .links = links,
            .allocator = allocator,
        };
    }

    pub fn init(allocator: Allocator, p: Parser) !@This() {
        var parser = p;
        // var links = std.StringArrayHashMap(Link).init(allocator);
        var links = std.ArrayList(Link).init(allocator);

        while (try parser.next(allocator)) |link| {
            const link_ = try link.clone(allocator);
            // std.debug.print("{}", .{link_});
            // try links.put(link_.path, link_);

            // const v = try links.getOrPut(link_.path);
            // if (v.found_existing) {
            //     print("Manifest.init error: {}\n", .{link_});
            //     return Error.DuplicateManifestEntry;
            // }
            // v.value_ptr.* = link_;
            try links.append(link_);
        }

        return .{
            .links = links,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        // var iter = self.links.iterator();
        // while (iter.next()) |entry| {
        //     entry.value_ptr.*.deinit(self.allocator);
        // }
        for (self.links.items) |link| {
            link.deinit(self.allocator);
        }
        self.links.deinit();
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
        // var iter = self.links.iterator();
        // while (iter.next()) |entry| {
        //     const link = entry.value_ptr.*;
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
    noop: []Link,
    add: []Link,
    remove: []Link,
    update: []UpdateLink,
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
            return Link.init(allocator, self.target, self.path);
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
            _ = try writer.print("{s} -> ({s} != {s})", .{ self.path, self.target, self.new_target });
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
        var current_map = std.StringHashMap(Link).init(allocator);
        defer current_map.deinit();
        for (current.links.items) |l| try current_map.put(l.path, l);

        // next_map = std.StringHashMap(Link).init(allocator);
        // defer next_map.deinit();
        // for (next.links.items) |l| try next_map.put(l.path, l);

        var noop = std.ArrayList(Link).init(allocator);
        defer noop.deinit();

        var add = std.ArrayList(Link).init(allocator);
        defer add.deinit();

        var remove = std.ArrayList(Link).init(allocator);
        defer remove.deinit();

        var update = std.ArrayList(UpdateLink).init(allocator);
        defer update.deinit();

        var keep = std.StringHashMap(void).init(allocator);
        defer keep.deinit();

        for (next.links.items) |link| {
        // var next_iter = next.links.iterator();
        // while (next_iter.next()) |entry| {
        //     const link = entry.value_ptr.*;
            try keep.put(link.path, void{});

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
        // var cur_iter = current.links.iterator();
        // while (cur_iter.next()) |entry| {
        //     const cur_link = entry.value_ptr.*;
            if (keep.get(cur_link.path) == null) {
                try remove.append(try cur_link.clone(allocator));
            }
        }

        return .{
            .noop = try allocator.dupe(Link, noop.items),
            .add = try allocator.dupe(Link, add.items),
            .remove = try allocator.dupe(Link, remove.items),
            .update = try allocator.dupe(UpdateLink, update.items),
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

    pub fn no_diff(self: @This()) bool {
        return self.add.len + self.remove.len + self.update.len == 0;
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
            _ = try writer.print("  ~ {s} -> {s}\n", .{ uplink.path, uplink.new_target });
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
        .noop = @constCast(&[_]Link{.{ .target = "target1", .path = "path1" }}),
        .add = @constCast(&[_]Link{.{ .target = "target4", .path = "path4" }}),
        .remove = @constCast(&[_]Link{.{ .target = "target2", .path = "path2" }}),
        .update = @constCast(&[_]Planner.UpdateLink{.{
            .target = "target3",
            .path = "path3",
            .new_target = "target5",
        }}),
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

    std.debug.print("{}\n", .{manifest_current});
    std.debug.print("{}\n", .{manifest_next});
    std.debug.print("{}\n", .{planner});

    try std.testing.expect(expect.eql(planner));
}
