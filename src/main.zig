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

// const Error = error{
//     SymlinkChanged,
//     SymlinkAlreadyExists,
// };

const ExitCodes = enum(u8) {
    generic = 1,
    invalid_option = 2,
    inconsistent_state = 3,
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
    code: ExitCodes = .generic,
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
    std.process.exit(@intFromEnum(flags.code));
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// const CommandFlags = struct {
//     verbose: bool = false,
// };

pub fn main() !void {
    var exec_flags: resolve.ExecPlanFlags = .{};

    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) {
            try usage();
            std.process.exit(1);
        } else if (eql(arg, "-n") or eql(arg, "--dry")) {
            exec_flags.dry = true;
        } else if (eql(arg, "-o") or eql(arg, "--overwrite")) {
            exec_flags.overwrite_mode = .overwrite;
        } else if (eql(arg, "-v") or eql(arg, "--verbose")) {
            exec_flags.verbose = true;
        } else if (eql(arg, "-s") or eql(arg, "--script")) {
            exec_flags.script = true;
        } else {
            try err("No option '{s}'", .{arg}, .{ .usage = true, .code = .invalid_option });
        }
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const home_env = std.posix.getenv("HOME").?;

    var zink_paths = std.ArrayList([]const u8).init(allocator);
    defer zink_paths.deinit();

    if (std.posix.getenv("ZINK_PATH")) |path_env| {
        var zink_path_iter = std.mem.split(u8, path_env, ":");
        while (zink_path_iter.next()) |zp| try zink_paths.append(zp);
    } else {
        const zink_path = try std.mem.concat(allocator, u8, &.{ home_env, "/.zink" });
        try zink_paths.append(zink_path);
    }

    var log_path: []const u8 = undefined;
    if (std.posix.getenv("ZINK_LOG_PATH")) |path_env| {
        log_path = path_env;
    } else {
        log_path = try std.mem.concat(allocator, u8, &.{ home_env, "/.zink.state" });
    }

    // Execute plan
    resolve.execPlan(allocator, log_path, zink_paths.items, exec_flags) catch |e| {
        switch (e) {
            resolve.Error.OverwriteModeNoDiff, resolve.Error.InconsistentState => {
                try err("Inconsistent state, use --overwrite to ignore this", .{}, .{ .code = .inconsistent_state });
            },
            else => return e,
        }
    };
}
