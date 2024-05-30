const std = @import("std");
const Utf8Iterator = std.unicode.Utf8Iterator;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MAX_PATH_BYTES = std.fs.MAX_PATH_BYTES;
const print = std.debug.print;

const resolve = @import("fs.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;
const Manifest = @import("planner.zig").Manifest;
const Planner = @import("planner.zig").Planner;

const Error = error{
    LogInconsistent,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // var buf: [MAX_PATH_BYTES]u8 = undefined;
    // const manifest_paths = try std.fs.cwd().realpath("/home/icetan/.ln-conf", &buf);
    var manifest_log = (try resolve.readManifests(allocator, &[_][]const u8{
        "./manifest.log.zink",
    })).?;
    defer manifest_log.deinit();
    // std.debug.print("Log Manifest: {}\n", .{manifest_log});

    var manifest = (try resolve.readManifests(allocator, &[_][]const u8{
        "/home/icetan/.ln-conf",
        "/home/icetan/.nix-profile/etc/ln-conf.d/*",
    })).?;
    defer manifest.deinit();
    // std.debug.print("New Manifest: {}\n", .{manifest});


    var verified_log = try resolve.verify(allocator, "", manifest_log);
    defer verified_log.deinit();
    // std.debug.print("fs: {}\n", .{verified_log});
    // std.debug.print("log: {}\n", .{manifest_log});
    var diff = try Planner.init(allocator, verified_log, manifest_log);
    // var diff = try resolve.verifyManifest(allocator, manifest_log);
    defer diff.deinit();

    // std.debug.print("Log diff: {}\n", .{diff});
    const overwrite_mode: resolve.ExecPlanOverwriteMode = .overwrite;

    if (overwrite_mode == .no_diff and !diff.no_diff()) {
        return Error.LogInconsistent;
    }

    var planner = try Planner.init(allocator, verified_log, manifest);
    defer planner.deinit();
    // std.debug.print("Result: {}\n", .{planner});

    try resolve.execPlan(planner, .{
        .overwrite_mode = overwrite_mode,
        .dry = false,
    });
    try resolve.saveManifestFile(manifest, "./manifest.log.zink");
}
