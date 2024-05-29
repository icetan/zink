const std = @import("std");
const Utf8Iterator = std.unicode.Utf8Iterator;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MAX_PATH_BYTES = std.fs.MAX_PATH_BYTES;
const print = std.debug.print;

const verify = @import("fs.zig").verify;
const resolve = @import("fs.zig").resolve;
const manifestFromPath = @import("fs.zig").manifestFromPath;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;
const Manifest = @import("planner.zig").Manifest;
const Planner = @import("planner.zig").Planner;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var buf: [MAX_PATH_BYTES]u8 = undefined;
    const manifest_path = try std.fs.cwd().realpath("/home/icetan/.ln-conf", &buf);
    const manifest_dir = std.fs.path.dirname(manifest_path).?;
    var manifest = try manifestFromPath(allocator, manifest_path);
    defer manifest.deinit();

    const manifest_next_path = try std.fs.cwd().realpath("/home/icetan/manifest.zink", &buf);
    var manifest_next = try manifestFromPath(allocator, manifest_next_path);
    defer manifest_next.deinit();

    var manifest_current = try verify(allocator, manifest_dir, manifest);
    defer manifest_current.deinit();
    std.debug.print("Current Manifest: {}\n", .{manifest_current});

    std.debug.print("Next Manifest: {}\n", .{manifest_next});

    var planner = try Planner.init(allocator, manifest_current, manifest_next);
    defer planner.deinit();
    std.debug.print("Result: {}\n", .{planner});
}
