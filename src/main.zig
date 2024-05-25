const std = @import("std");
const Utf8Iterator = std.unicode.Utf8Iterator;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MAX_PATH_BYTES = std.fs.MAX_PATH_BYTES;
const print = std.debug.print;

// const json = @import("json");
const Glob = @import("glob").Iterator;

const verify = @import("fs.zig").verify;
const resolve = @import("fs.zig").resolve;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;
const Manifest = @import("planner.zig").Manifest;
const Planner = @import("planner.zig").Planner;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer std.debug.assert(!gpa.deinit());
    var allocator = gpa.allocator();
    // const stdout = std.io.getStdOut().writer();

    var buf: [MAX_PATH_BYTES]u8 = undefined;
    const manifest_path = try std.fs.cwd().realpath("/home/icetan/.ln-conf", &buf);
    const manifest_file = try readManifest(allocator, manifest_path);
    defer allocator.free(manifest_file);

    var dir_iter = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir_iter.close();
    var glob = try Glob.init(allocator, dir_iter, "src/*.zig");
    while (try glob.next()) |p| {
        print("glob: {s}\n", .{p});
    }

    // try stdout.print("Manifest:\n\n{s}\n", .{manifest_file});
    // try stdout.print("buf length {d}\n", .{manifest_file.len});

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
    // std.debug.print("{}\n", .{manifest});

    // var buf: [MAX_PATH_BYTES]u8 = undefined;
    const abs_base = std.fs.path.dirname(manifest_path).?;

    var abs_manifest = try resolve(allocator, abs_base, manifest);
    defer abs_manifest.deinit();
    std.debug.print("{}\n", .{abs_manifest});

    var fs_manifest = try verify(allocator, abs_base, abs_manifest);
    defer fs_manifest.deinit();
    std.debug.print("{}\n", .{fs_manifest});

    var planner = try Planner.init(allocator, fs_manifest, abs_manifest);
    defer planner.deinit();
    std.debug.print("{}\n", .{planner});
}

fn readManifest(allocator: Allocator, file_path: []const u8) ![]u8 {
    const dir = std.fs.cwd();
    const file = try dir.openFile(file_path, .{});
    return try file.readToEndAlloc(allocator, 1000 * 1000 * 5); // Max 5MB file size
}
