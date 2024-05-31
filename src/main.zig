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
    SymlinkChanged,
    SymlinkAlreadyExists,
};

fn usage() !void {
    var args = std.process.args();
    const pname = args.next().?;
    try std.io.getStdErr().writer().print(
        \\Usage: {s} [OPTIONS]
        \\  --dry, -n
        \\  --overwrite, -o
        \\  --help, h
        \\
    , .{std.fs.path.basename(pname)});
    std.process.exit(1);
}

const ErrFlags = struct {
    code: u8 = 1,
    usage: bool = false,
};

fn err(comptime msg: []const u8, values: anytype, flags: ErrFlags) !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("ERROR: ", .{});
    try stderr.print(msg, values);
    try stderr.print("\n", .{});
    if (flags.usage) {
        try usage();
    }
    std.process.exit(flags.code);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn main() !void {
    // const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var flags: resolve.ExecPlanFlags = .{
        .overwrite_mode = .no_diff,
        .dry = false,
    };

    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (eql(arg, "--help") or eql(arg, "-h")) {
            try usage();
            std.process.exit(1);
        } else if (eql(arg, "--dry") or eql(arg, "-n")) {
            flags.dry = true;
        } else if (eql(arg, "--overwrite") or eql(arg, "-o")) {
            flags.overwrite_mode = .overwrite;
        } else {
            try err("No option '{s}'", .{arg}, .{ .usage = true, .code = 2 });
        }
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var manifest_log = (try resolve.readManifests(allocator, &[_][]const u8{
        "./manifest.log.zink",
    })).?;
    defer manifest_log.deinit();

    var manifest = (try resolve.readManifests(allocator, &[_][]const u8{
        "/home/icetan/.ln-conf",
        "/home/icetan/.nix-profile/etc/ln-conf.d/*",
    })).?;
    defer manifest.deinit();

    var verified_log = try resolve.verify(allocator, "", manifest_log);
    defer verified_log.deinit();
    var log_diff = try Planner.init(allocator, verified_log, manifest_log);
    defer log_diff.deinit();

    var verified_manifest = try resolve.verify(allocator, "", manifest);
    defer verified_manifest.deinit();

    var planner = try Planner.init(allocator, verified_log, manifest);
    defer planner.deinit();
    // std.debug.print("log_diff: {}\n", .{log_diff});
    // std.debug.print("planner: {}\n", .{planner});

    if (flags.overwrite_mode == .no_diff and log_diff.update.len > 0) {
        // return Error.SymlinkChanged;
        for (log_diff.update) |link| {
            try stderr.print("File not consistent with previous run: {}\n", .{link});
        }
        try err("Inconsistent state, use --overwrite to ignore this", .{}, .{ .code = 4 });
    }

    resolve.execPlan(planner, flags) catch |e| {
        switch (e) {
            resolve.Error.OverwriteModeNoDiff => {
                try err("Inconsistent state, use --overwrite to ignore this", .{}, .{ .code = 4 });
            },
            else => return e,
        }
    };
    if (!flags.dry) {
        try resolve.saveManifestFile(manifest, "./manifest.log.zink");
    }
}
