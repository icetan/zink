const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const Dir = std.fs.Dir;
const assert = std.debug.assert;
const print = std.debug.print;

const MAX_PATH_BYTES = fs.MAX_PATH_BYTES;

const Glob = @import("glob").Iterator;

const planner = @import("planner.zig");
const Manifest = planner.Manifest;
const Planner = planner.Planner;
const UpdateLink = planner.Planner.UpdateLink;
const Link = @import("parser.zig").Link;
const Parser = @import("parser.zig").Parser;
const Tokenizer = @import("tokenizer.zig").Tokenizer;

const Error = error{
    ManifestPathMustBeAbsolute,
    PathMustBeAbsolute,
    LinkPathMustBeDirWithGlob,
    ResolveLinkError,
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
        if (!fs.path.isAbsolute(path)) {
            return Error.PathMustBeAbsolute;
        }
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

    const abs_target = try resolvePath(allocator, path, link.target);
    defer allocator.free(abs_target);

    const target_glob_index = std.mem.indexOf(u8, abs_target, "*");

    if (!path_is_dir and target_glob_index != null) {
        // print("\nassert path: {s}, target: {s}\n", .{ abs_path, abs_target });
        return Error.LinkPathMustBeDirWithGlob;
    }

    if (path_is_dir) {
        if (target_glob_index) |index| {
            const dir_name = fs.path.dirname(abs_target[0..index]).?;
            // print("glob target dir: {s} -> {s}\n", .{dir_name, abs_target});
            var dir_iter = try std.fs.cwd().openDir(
                dir_name,
                .{ .iterate = true },
            );
            defer dir_iter.close();

            const target_pattern_index = dir_name.len + 1;
            var glob = try Glob.init(allocator, dir_iter, abs_target[target_pattern_index..]);
            defer glob.deinit();
            while (try glob.next()) |file_path| {
                const target_basename = std.fs.path.basename(file_path);
                const target_file = try std.fs.path.join(allocator, &[_][]const u8{ dir_name, file_path });
                defer allocator.free(target_file);
                const path_file = try std.fs.path.join(allocator, &[_][]const u8{ abs_path, target_basename });
                defer allocator.free(path_file);

                const link__ = try Link.init(
                    allocator,
                    target_file,
                    path_file,
                );
                try fs_links.append(link__);
                // print("glob found link: {}\n", .{link__});
            }
        } else {
            const target_basename = std.fs.path.basename(abs_target);
            const abs_path_ = try std.fs.path.join(allocator, &[_][]const u8{ abs_path, target_basename });
            defer allocator.free(abs_path_);
            try fs_links.append(try Link.init(
                allocator,
                abs_target,
                abs_path_,
            ));
        }
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

    for (manifest.links.items) |link| {
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

    for (manifest.links.items) |link| {
        const resolved_links = try resolveLink(allocator, path, link);
        try links.appendSlice(resolved_links);
    }

    return Manifest.initLinks(allocator, links.items);
}

pub fn readFile(allocator: Allocator, file_path: []const u8) ![]u8 {
    const dir = std.fs.cwd();
    const file = try dir.openFile(file_path, .{});
    return try file.readToEndAlloc(allocator, 1000 * 1000 * 5); // Max 5MB file size
}

pub fn manifestFromPath(allocator: Allocator, path: []const u8) !Manifest {
    var buf: [MAX_PATH_BYTES]u8 = undefined;
    const manifest_path = try std.fs.cwd().realpath(path, &buf);
    const manifest_dir = std.fs.path.dirname(manifest_path).?;
    const manifest_file = try readFile(allocator, manifest_path);
    defer allocator.free(manifest_file);

    var tokenizer = try Tokenizer.init(allocator, manifest_file);
    defer tokenizer.deinit();

    const EnvLookup = struct {
        pub fn lookup(name: []const u8) ?[]const u8 {
            return std.posix.getenv(name);
        }
    };

    var parser = Parser.init(allocator, tokenizer, EnvLookup.lookup);
    defer parser.deinit();

    var manifest = try Manifest.init(allocator, parser);
    defer manifest.deinit();

    return try resolve(allocator, manifest_dir, manifest);
}

test "verify manifest" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink("target1", "path1", .{});
    try tmp.dir.symLink("target3", "path3", .{});

    var buf: [MAX_PATH_BYTES]u8 = undefined;
    const abs_base = try tmp.dir.realpath(".", &buf);

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
            .path = "path1",
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
        // .{ .{ .target = "./target1", .path = "path1" }, .{ .changed = .{
        //     .target = "target1",
        //     .path = "path1",
        //     .new_target = "target1",
        // } } },
    };

    for (matrix) |row| {
        const link = row[0];
        const diff_link = row[1];

        // print("link={any}\n", .{link});
        const result = try verifyLink(allocator, abs_base, link);
        defer result.deinit(allocator);

        print("expected: {}\n", .{diff_link});
        print("got: {}\n", .{result});

        try expectEqualDiffLink(allocator, abs_base, diff_link, result);
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

    const matrix = [_]struct { Link, Error![]Link }{
        .{
            .{ .target = "./*", .path = "path1" },
            Error.LinkPathMustBeDirWithGlob,
        },
        .{
            .{ .target = "./*", .path = "path1/" },
            @constCast(&[_]Link{
                .{ .target = "target1", .path = "path1/target1" },
                .{ .target = "target3", .path = "path1/target3" },
            }),
        },
    };

    for (matrix) |row| {
        const link = row[0];
        const expect_links = row[1];

        print("\nexpected {any}\n", .{expect_links});

        var result: Error![]Link = undefined;
        if (resolveLink(allocator, abs_base, link)) |r| {
            result = r;
        } else |err| {
            result = switch (err) {
                Error.PathMustBeAbsolute => Error.PathMustBeAbsolute,
                Error.LinkPathMustBeDirWithGlob => Error.LinkPathMustBeDirWithGlob,
                else => Error.ResolveLinkError,
            };
            print("resolve error: {}\n", .{err});
        }

        print("got {any}\n", .{result});

        if (result) |result_| {
            const expect_links_ = try expect_links;
            defer {
                for (result_) |l| {
                    l.deinit(allocator);
                }
                allocator.free(result_);
            }
            try std.testing.expectEqual(expect_links_.len, result_.len);
            for (expect_links_, 0..) |expect_link, i| {
                try expectEqualLink(allocator, abs_base, expect_link, result_[i]);
            }
            // try std.testing.expectEqualDeep(expect_links, result);
        } else |err| {
            try std.testing.expectEqual(expect_links, err);
        }
    }
}

fn expectEqualLink(allocator: Allocator, tmp_path: []const u8, exp: Link, res: Link) !void {
    const res_target = try std.fs.path.relative(allocator, tmp_path, res.target);
    defer allocator.free(res_target);
    const res_path = try std.fs.path.relative(allocator, tmp_path, res.path);
    defer allocator.free(res_path);
    try std.testing.expectEqualStrings(exp.target, res_target);
    try std.testing.expectEqualStrings(exp.path, res_path);
}

fn expectEqualUpdateLink(allocator: Allocator, tmp_path: []const u8, exp: UpdateLink, res: UpdateLink) !void {
    const res_target = try std.fs.path.relative(allocator, tmp_path, res.target);
    defer allocator.free(res_target);
    const res_path = try std.fs.path.relative(allocator, tmp_path, res.path);
    defer allocator.free(res_path);
    const res_new_target = try std.fs.path.relative(allocator, tmp_path, res.new_target);
    defer allocator.free(res_new_target);
    try std.testing.expectEqualStrings(exp.target, res_target);
    try std.testing.expectEqualStrings(exp.path, res_path);
    try std.testing.expectEqualStrings(exp.new_target, res_new_target);
}

fn expectEqualDiffLink(allocator: Allocator, tmp_path: []const u8, exp: DiffLink, res: DiffLink) !void {
    try std.testing.expectEqual(@tagName(exp), @tagName(res));
    try switch (exp) {
        .ok => |link| expectEqualLink(allocator, tmp_path, link, res.ok),
        .changed => |uplink| expectEqualUpdateLink(allocator, tmp_path, uplink, res.changed),
        .missing => {},
    };
}
