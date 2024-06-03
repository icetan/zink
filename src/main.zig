const std = @import("std");
const Utf8Iterator = std.unicode.Utf8Iterator;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MAX_PATH_BYTES = std.fs.MAX_PATH_BYTES;
const print = std.debug.print;

const resolve = @import("fs.zig");

const ExitCodes = enum(u8) {
    generic = 1,
    invalid_option = 2,
    inconsistent_state = 3,
};

fn usage() !void {
    var args = std.process.args();
    const pname = args.next().?;
    try std.io.getStdErr().writer().print(
        \\Usage: {s} [OPTIONS] [MANIFEST..]
        \\
        \\Options:
        \\  -n, -dry           Don't apply any changes
        \\  -o, -overwrite     Ignore and overwrite existing links
        \\  -s, -script        Implies -dry
        \\  -v, -verbose       Print existing links and extra info
        \\  -h, -help          Print this message
        \\
        \\Manifest: Files to apply
        \\
        \\Envs:
        \\  ZINK_PATH           Manifest files to apply, delimit with ':'
        \\  ZINK_LOG_PATH       State file to use
        \\
    , .{std.fs.path.basename(pname)});
}

const ErrFlags = struct {
    code: ExitCodes = .generic,
    usage: bool = false,
};

fn err(comptime msg: []const u8, values: anytype, flags: ErrFlags) !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("error: ", .{});
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var zink_paths = std.ArrayList([]const u8).init(allocator);
    defer zink_paths.deinit();

    var exec_flags: resolve.ExecPlanFlags = .{};

    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "-help")) {
            try usage();
            std.process.exit(0);
        } else if (eql(arg, "-n") or eql(arg, "-dry")) {
            exec_flags.dry = true;
        } else if (eql(arg, "-o") or eql(arg, "-overwrite")) {
            exec_flags.overwrite_mode = .overwrite;
        } else if (eql(arg, "-v") or eql(arg, "-verbose")) {
            exec_flags.verbose = true;
        } else if (eql(arg, "-s") or eql(arg, "-script")) {
            exec_flags.script = true;
        } else if (arg[0] == '-') {
            try err("No option '{s}'", .{arg}, .{ .usage = true, .code = .invalid_option });
        } else {
            try zink_paths.append(arg);
        }
    }

    const home_env = std.posix.getenv("HOME").?;

    if (zink_paths.items.len == 0) {
        if (std.posix.getenv("ZINK_PATH")) |path_env| {
            var zink_path_iter = std.mem.split(u8, path_env, ":");
            while (zink_path_iter.next()) |zp| try zink_paths.append(zp);
        } else {
            const zink_path = try std.mem.concat(allocator, u8, &.{ home_env, "/.zink" });
            defer allocator.free(zink_path);
            try zink_paths.append(zink_path);
        }
    }

    var log_path: []const u8 = undefined;
    if (std.posix.getenv("ZINK_LOG_PATH")) |path_env| {
        log_path = path_env;
    } else {
        log_path = try std.mem.concat(allocator, u8, &.{ home_env, "/.zink.state" });
        defer allocator.free(log_path);
    }

    // Execute plan
    resolve.execPlan(allocator, log_path, zink_paths.items, exec_flags) catch |e| {
        switch (e) {
            resolve.Error.OverwriteModeNoDiff, resolve.Error.InconsistentState => {
                try err("Inconsistent state, use -overwrite to ignore this", .{}, .{ .code = .inconsistent_state });
            },
            else => return e,
        }
    };
}
