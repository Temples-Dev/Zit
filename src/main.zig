const std = @import("std");
const Io = std.Io;

const cmd_init = @import("cmd/init.zig");
const cmd_hash_object = @import("cmd/hash_object.zig");
const cmd_cat_file = @import("cmd/cat_file.zig");
const errors = @import("errors.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stdout: *Io.Writer = &stdout_fw.interface;
    const stderr: *Io.Writer = &stderr_fw.interface;

    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try printUsage(stderr);
        std.process.exit(1);
    }

    const subcmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, subcmd, "init")) {
        cmd_init.run(arena, io, rest, stdout) catch |err| {
            try errors.print(stderr, "init", err, null);
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, subcmd, "hash-object")) {
        cmd_hash_object.run(arena, io, rest, stdout, stderr) catch {
            // Error already printed by hash_object.run using errors.print
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, subcmd, "cat-file")) {
        cmd_cat_file.run(arena, io, rest, stdout, stderr) catch {
            // Error already printed by cat_file.run using errors.print
            try stderr.flush();
            std.process.exit(1);
        };
    } else {
        try stderr.print("zit: unknown command '{s}'\n\n", .{subcmd});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }
}

fn printUsage(w: *Io.Writer) !void {
    try w.writeAll(
        \\usage: zit <command> [<args>]
        \\
        \\Plumbing commands:
        \\   init           Create a new repository
        \\   hash-object    Compute object ID and optionally write to store
        \\   cat-file       Inspect object type, size, or content
        \\
    );
}
