const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const Dir = std.fs.Dir;
const assert = std.debug.assert;
const print = std.debug.print;

const MAX_PATH_BYTES = fs.MAX_PATH_BYTES;

const planner = @import("planner.zig");
const Manifest = planner.Manifest;
const Planner = planner.Planner;
const UpdateLink = planner.Planner.UpdateLink;

const parser = @import("parser.zig");
const Link = parser.Link;

const Error = error{
    ManifestPathMustBeAbsolute,
};

const DiffLink = union(enum) {
    ok: Link,
    missing,
    changed: UpdateLink,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        switch (self) {
            .missing => {},
            .ok => |link| link.deinit(allocator),
            .changed => |uplink| uplink.deinit(allocator),
        }
    }
};

fn resolvePath(allocator: Allocator, path: []const u8, rel_path: []const u8) ![]const u8 {
    var paths: []const []const u8 = undefined;
    if (fs.path.isAbsolute(rel_path)) {
        paths = &[_][]const u8{rel_path};
    } else {
        assert(fs.path.isAbsolute(path));
        paths = &[_][]const u8{ path, rel_path };
    }
    return fs.path.resolve(allocator, paths);
}

fn resolveTargetPath(allocator: Allocator, path: []const u8, rel_path: []const u8) ![]const u8 {
    const abs = try resolvePath(allocator, path, rel_path);
    defer allocator.free(abs);

    var buf: [MAX_PATH_BYTES]u8 = undefined;
    const target = try fs.readLinkAbsolute(abs, &buf);
    return resolvePath(allocator, fs.path.dirname(abs).?, target);
}

fn resolveLink(allocator: Allocator, path: []const u8, link: Link) ![]Link {
    var fs_links = std.ArrayList(Link).init(allocator);
    defer fs_links.deinit();

    const path_is_dir = link.path[link.path.len - 1] == '/';
    const abs_path = try resolvePath(allocator, path, link.path);
    defer allocator.free(abs_path);

    const target_basename = std.fs.path.basename(link.target);
    const target_is_glob = target_basename[target_basename.len - 1] == '*';
    if (target_is_glob and !path_is_dir) {
        return allocator.alloc(Link, 0);
    }

    const abs_target = try resolvePath(allocator, path, link.target);
    defer allocator.free(abs_target);

    if (path_is_dir) {
        if (target_is_glob) {
            // TODO: expand globs */?/{}
        }
        const buf = try allocator.alloc(u8, abs_path.len + target_basename.len);
        const abs_path_ = try std.fmt.bufPrint(buf, "{s}{s}", .{ abs_path, target_basename });
        defer allocator.free(abs_path_);
        try fs_links.append(try Link.init(
            allocator,
            abs_target,
            abs_path_,
        ));
    } else {
        try fs_links.append(try Link.init(
            allocator,
            abs_target,
            abs_path,
        ));
    }
    return try allocator.dupe(Link, fs_links.items);
}

fn verifyLink(allocator: Allocator, path: []const u8, link: Link) !DiffLink {
    const abs_path = try resolvePath(allocator, path, link.path);
    defer allocator.free(abs_path);

    const abs_target = try resolvePath(allocator, path, link.target);
    defer allocator.free(abs_target);

    const current_target = resolveTargetPath(allocator, path, abs_path) catch {
        return .{ .missing = {} };
    };
    defer allocator.free(current_target);

    if (std.mem.eql(u8, abs_target, current_target)) {
        return .{ .ok = try Link.init(
            allocator,
            current_target,
            abs_path,
        ) };
    } else {
        return .{ .changed = try UpdateLink.init(
            allocator,
            current_target,
            abs_path,
            abs_target,
        ) };
    }
}

pub fn verify(allocator: Allocator, path: []const u8, manifest: Manifest) !Manifest {
    var fs_links = std.ArrayList(Link).init(allocator);
    defer fs_links.deinit();

    var iter = manifest.links.iterator();
    while (iter.next()) |entry| {
        const link = entry.value_ptr.*;
        const diff_link = try verifyLink(allocator, path, link);
        defer diff_link.deinit(allocator);

        switch (diff_link) {
            .missing => {},
            .ok => |l| {
                try fs_links.append(try l.clone(allocator));
            },
            .changed => |uplink| {
                try fs_links.append(try uplink.toLink(allocator));
            },
        }
    }

    const fs_manifest = try Manifest.initLinks(allocator, fs_links.items);
    defer for (fs_links.items) |link| {
        link.deinit(allocator);
    };

    return fs_manifest;
}

pub fn resolve(allocator: Allocator, path: []const u8, manifest: Manifest) !Manifest {
    var links = std.ArrayList(Link).init(allocator);
    defer links.deinit();

    var iter = manifest.links.iterator();
    while (iter.next()) |entry| {
        const link = entry.value_ptr.*;
        const resolved_links = try resolveLink(allocator, path, link);
        try links.appendSlice(resolved_links);
    }

    return Manifest.initLinks(allocator, links.items);
}

test "verify manifest" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink("target1", "path1", .{});
    try tmp.dir.symLink("target3", "path3", .{});

    var buf: [MAX_PATH_BYTES]u8 = undefined;
    const abs_base = try tmp.dir.realpath(".", &buf);
    // const base_path = ".";
    // try tmp.dir.setAsCwd();

    const matrix = [_]struct { []Link, Manifest }{
        .{
            @constCast(&[_]Link{
                .{ .target = "target1", .path = "path1" },
            }),
            try Manifest.initLinks(allocator, @constCast(&[_]Link{
                .{ .target = "target1", .path = "path1" },
            })),
        },
        .{
            @constCast(&[_]Link{
                .{ .target = "target1", .path = "path1" },
                .{ .target = "target3", .path = "path3" },
            }),
            try Manifest.initLinks(allocator, @constCast(&[_]Link{
                .{ .target = "target1", .path = "path1" },
                .{ .target = "target3", .path = "path3" },
            })),
        },
        .{
            @constCast(&[_]Link{
                .{ .target = "target1", .path = "path1" },
                .{ .target = "target2", .path = "path2" },
            }),
            try Manifest.initLinks(allocator, @constCast(&[_]Link{
                .{ .target = "target1", .path = "path1" },
            })),
        },
        .{
            @constCast(&[_]Link{
                .{ .target = "target1", .path = "path1" },
                .{ .target = "target2", .path = "path2" },
                .{ .target = "target5", .path = "path3" },
            }),
            try Manifest.initLinks(allocator, @constCast(&[_]Link{
                .{ .target = "target1", .path = "path1" },
                .{ .target = "target3", .path = "path3" },
            })),
        },
    };
    defer for (matrix) |row| {
        var manifest = row[1];
        manifest.deinit();
    };

    for (matrix) |row| {
        const links = row[0];
        const expect_manifest = row[1];

        var manifest = try Manifest.initLinks(allocator, links);
        defer manifest.deinit();

        var result = try verify(allocator, abs_base, manifest);
        defer result.deinit();

        print("\nexpected {}\n", .{expect_manifest});
        print("got {}\n", .{result});
        try std.testing.expect(expect_manifest.eql(result));
    }
}

test "verify link" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink("target1", "path1", .{});

    var buf: [MAX_PATH_BYTES]u8 = undefined;
    const abs_base = try tmp.dir.realpath(".", &buf);
    print("base path: {s}\n", .{abs_base});

    const matrix = [_]struct { Link, DiffLink }{
        .{ .{ .target = "target1", .path = "path1" }, .{ .ok = .{
            .target = "target1",
            .path = "path1",
        } } },
        .{ .{ .target = "target1", .path = "./path1" }, .{ .ok = .{
            .target = "target1",
            .path = "./path1",
        } } },
        .{ .{ .target = "target1", .path = "./hej/../path1" }, .{ .ok = .{
            .target = "target1",
            .path = "path1",
        } } },
        .{ .{ .target = "target1", .path = "path2" }, .{ .missing = {} } },
        .{ .{ .target = "target2", .path = "path2" }, .{ .missing = {} } },
        .{ .{ .target = "target3", .path = "path1" }, .{ .changed = .{
            .target = "target1",
            .path = "path1",
            .new_target = "target3",
        } } },
        .{ .{ .target = "./target1", .path = "path1" }, .{ .changed = .{
            .target = "target1",
            .path = "path1",
            .new_target = "./target1",
        } } },
    };

    for (matrix) |row| {
        const link = row[0];
        const diff_link = row[1];

        // print("link={any}\n", .{link});
        const result = try verifyLink(allocator, abs_base, link);
        defer result.deinit(allocator);

        print("expected: {}\n", .{diff_link});
        print("got: {}\n", .{result});

        try std.testing.expectEqualDeep(diff_link, result);
        // switch (diff_link) {
        //     .missing => try std.testing.expectEqual(diff_link, result),
        //     .ok => |l| {
        //         try std.testing.expectEqualDeep(l, result.ok);
        //         try std.testing.expect(l.eql(result.ok));
        //     },
        //     .changed => |uplink| {
        //         // print("expect link={any}, got link={any}\n", .{ diff_link.changed.link, result.changed.link });
        //         // try std.testing.expectEqualDeep(uplink, result.changed);
        //         try std.testing.expect(uplink.eql(result.changed));
        //     },
        // }
    }
}

test "resolve link" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target1 = try tmp.dir.createFile("target1", .{});
    target1.close();
    const target3 = try tmp.dir.createFile("target3", .{});
    target3.close();

    var buf: [MAX_PATH_BYTES]u8 = undefined;
    const abs_base = try tmp.dir.realpath(".", &buf);

    const matrix = [_]struct { Link, ?[]Link }{
        .{
            .{ .target = "*", .path = "path1" },
            @constCast(&[_]Link{}),
        },
        .{
            .{ .target = "*", .path = "path1/" },
            @constCast(&[_]Link{
                .{ .target = "target1", .path = "path1/target1" },
                .{ .target = "target3", .path = "path1/target3" },
            }),
        },
    };

    for (matrix) |row| {
        const link = row[0];
        const expect_links = row[1];

        const result = try resolveLink(allocator, abs_base, link);
        defer {
            for (result) |l| {
                l.deinit(allocator);
            }
            allocator.free(result);
        }

        try std.testing.expectEqualDeep(expect_links, result);
    }
}
