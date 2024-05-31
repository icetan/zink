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
const parser = @import("parser.zig");
const Parser = parser.Parser;
const Link = parser.Link;
const Tokenizer = @import("tokenizer.zig").Tokenizer;

pub const Error = error{
    ManifestPathMustBeAbsolute,
    PathMustBeAbsolute,
    LinkPathMustBeDirWithGlob,
    ResolveLinkError,
    OverwriteModeNoDiff,
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

pub fn getGlobIter(allocator: Allocator, path: []const u8) !?struct { Glob, std.fs.Dir } {
    const glob_index = std.mem.indexOf(u8, path, "*") orelse {
        return null;
    };
    const dir_index = glob_index + 1;
    const dir_name = fs.path.dirname(path[0..dir_index]) orelse {
        return null;
    };
    const dir_iter = try std.fs.cwd().openDir(
        dir_name,
        .{ .iterate = true },
    );

    const pattern_index = dir_name.len + 1;
    const glob = try Glob.init(allocator, dir_iter, path[pattern_index..]);

    return .{ glob, dir_iter };
}

// pub fn globPath(allocator: Allocator, pattern: []const u8) []const u8 {
//     var glob = getGlobIter(allocator, pattern) orelse {
//         return allocator.dupe(u8, &[_]const u8{});
//     }
//     defer glob.deinit();

//     var file_paths = std.ArrayList([]const u8).init(allocator);
//     defer file_paths.deinit();

//     while (try glob.next()) |file_path| {
//         file_paths.append(allocator.dupe(u8, file_path));
//     }

//     return allocator.dupe(u8 file_paths.items);
// }

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
            abs_target,
            abs_path,
            current_target,
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
    // print("Reading manifest file {s}\n", .{path});
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

    var p = Parser.init(allocator, tokenizer, EnvLookup.lookup);
    defer p.deinit();

    var manifest = try Manifest.init(allocator, p);
    defer manifest.deinit();

    return try resolve(allocator, manifest_dir, manifest);
}

pub fn readManifests(allocator: Allocator, glob_paths: []const []const u8) !?Manifest {
    var manifest: ?Manifest = null;
    for (glob_paths) |glob_path| {
        // print("Path: {s}\n", .{glob_path});
        var buf: [MAX_PATH_BYTES]u8 = undefined;
        if (try getGlobIter(allocator, glob_path)) |x| {
            var glob = x[0];
            defer glob.deinit();
            var dir = x[1];
            defer dir.close();
            const dir_path = try dir.realpath(".", &buf);

            while (try glob.next()) |file_path_| {
                const basename = std.fs.path.basename(file_path_);
                const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, basename });
                defer allocator.free(file_path);
                // print("Glob: {s}\n", .{file_path});

                var m = try manifestFromPath(allocator, file_path);
                if (manifest) |*manifest_| {
                    defer m.deinit();
                    try manifest_.appendManifest(&m);
                } else {
                    manifest = m;
                }
            }
        } else {
            var m = try manifestFromPath(allocator, glob_path);
            if (manifest) |*manifest_| {
                defer m.deinit();
                try manifest_.appendManifest(&m);
            } else {
                manifest = m;
            }
        }
    }
    return manifest;
}

pub fn saveManifestFile(manifest: Manifest, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try manifest.save(file.writer());
}

// pub fn verifyManifest(allocator: Allocator, manifest: Manifest) !Planner {
//     var verified = try verify(allocator, "", manifest);
//     defer verified.deinit();
//     return try Planner.init(allocator, verified, manifest);
// }

pub const ExecPlanOverwriteMode = enum {
    no_diff,
    overwrite,
    move,
};

pub const ExecPlanFlags = struct {
    dry: bool = false,
    overwrite_mode: ExecPlanOverwriteMode = .no_diff,
};

pub fn execPlan(plan: Planner, flags: ExecPlanFlags) !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (flags.dry) try stderr.print("INFO: Dry run\n", .{});

    for (plan.add) |link| {
        if (fs.accessAbsolute(link.path, .{})) |_| {
            switch (flags.overwrite_mode) {
                .no_diff => {
                    try stderr.print("INFO: Symlink '{s}' already exists\n", .{link.path});
                    return Error.OverwriteModeNoDiff;
                },
                .overwrite => {
                    try stderr.print("INFO: Overwriting symlink '{s}'\n", .{link.path});
                    if (!flags.dry) {
                        try fs.deleteFileAbsolute(link.path);
                    }
                },
                .move => {
                    // TODO: move file
                    unreachable;
                },
            }
        } else |_| {}
    }

    for (plan.remove) |link| {
        if (!flags.dry) try fs.deleteFileAbsolute(link.path);
        try stdout.print("  - {}\n", .{link});
    }

    for (plan.add) |link| {
        if (!flags.dry) {
            try fs.symLinkAbsolute(link.target, link.path, .{});
        }
        try stdout.print("  + {}\n", .{link});
    }

    for (plan.update) |uplink| {
        if (!flags.dry) {
            try fs.deleteFileAbsolute(uplink.path);
            try fs.symLinkAbsolute(uplink.new_target, uplink.path, .{});
        }
        try stdout.print("  ~ {}\n", .{uplink});
    }
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
                .{ .target = "target5", .path = "path3" },
            })),
        },
    };
    defer for (matrix) |row| {
        var manifest = row[1];
        manifest.deinit();
    };

    for (matrix) |row| {
        const links = row[0];
        const expect = row[1];

        var manifest = try Manifest.initLinks(allocator, links);
        defer manifest.deinit();

        var got = try verify(allocator, abs_base, manifest);
        defer got.deinit();

        testing.expectEqualManifest(allocator, abs_base, expect, got) catch |err| {
            print("\nexpected: {}\ngot: {}\n", .{ expect, got });
            return err;
        };
    }
}

test "verify link" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink("target1", "path1", .{});

    var buf: [MAX_PATH_BYTES]u8 = undefined;
    const abs_base = try tmp.dir.realpath(".", &buf);
    // print("base path: {s}\n", .{abs_base});

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
            .target = "target3",
            .path = "path1",
            .new_target = "target1",
        } } },
    };

    for (matrix) |row| {
        const link = row[0];
        const diff_link = row[1];

        const result = try verifyLink(allocator, abs_base, link);
        defer result.deinit(allocator);

        testing.expectEqualDiffLink(allocator, abs_base, diff_link, result) catch |err| {
            print("\nexpected: {}\ngot {}\n", .{ diff_link, result });
            return err;
        };
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

        var result: Error![]Link = undefined;
        if (resolveLink(allocator, abs_base, link)) |r| {
            result = r;
        } else |err| {
            result = switch (err) {
                Error.PathMustBeAbsolute => Error.PathMustBeAbsolute,
                Error.LinkPathMustBeDirWithGlob => Error.LinkPathMustBeDirWithGlob,
                else => Error.ResolveLinkError,
            };
        }

        if (result) |result_| {
            const expect_links_ = try expect_links;
            defer {
                for (result_) |l| {
                    l.deinit(allocator);
                }
                allocator.free(result_);
            }
            testing.expectEqualLinks(allocator, abs_base, expect_links_, result_) catch |err| {
                print("expected: {any}\ngot: {any}\n", .{ expect_links_, result_ });
                return err;
            };
        } else |err| {
            try std.testing.expectEqual(expect_links, err);
        }
    }
}

pub const testing = struct {
    pub fn expectEqualDiffLink(allocator: Allocator, tmp_path: []const u8, exp: DiffLink, res: DiffLink) !void {
        try std.testing.expectEqual(@tagName(exp), @tagName(res));
        try switch (exp) {
            .ok => |link| testing.expectEqualLink(allocator, tmp_path, link, res.ok),
            .changed => |uplink| testing.expectEqualUpdateLink(allocator, tmp_path, uplink, res.changed),
            .missing => {},
        };
    }

    pub fn expectEqualUpdateLink(allocator: Allocator, tmp_path: []const u8, exp: Planner.UpdateLink, res: Planner.UpdateLink) !void {
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

    pub fn expectEqualLink(allocator: Allocator, tmp_path: []const u8, exp: Link, res: Link) !void {
        const res_target = try std.fs.path.relative(allocator, tmp_path, res.target);
        defer allocator.free(res_target);
        const res_path = try std.fs.path.relative(allocator, tmp_path, res.path);
        defer allocator.free(res_path);
        try std.testing.expectEqualStrings(exp.target, res_target);
        try std.testing.expectEqualStrings(exp.path, res_path);
    }

    pub fn expectEqualLinks(allocator: Allocator, tmp_path: []const u8, exp: []Link, res: []Link) !void {
        try std.testing.expectEqual(exp.len, res.len);
        for (exp, 0..) |link, i| {
            const link_ = res[i];
            try expectEqualLink(allocator, tmp_path, link, link_);
        }
    }

    pub fn expectEqualManifest(allocator: Allocator, tmp_path: []const u8, exp: Manifest, res: Manifest) !void {
        try expectEqualLinks(allocator, tmp_path, exp.links.items, res.links.items);
    }
};
