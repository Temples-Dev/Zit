//! `zit hash-object [-w] [-t <type>] <file>`
//!
//!   -w          write the object to the store (requires a repository)
//!   -t <type>   object type: blob (default), tree, commit, tag
//!   <file>      path to read; use `-` to read from stdin
const std = @import("std");
const Io = std.Io;
const Repo = @import("../repo.zig").Repo;
const Store = @import("../object/store.zig").Store;
const ObjectType = @import("../object/object.zig").ObjectType;
const errors = @import("../errors.zig");
const ZitError = errors.Error;

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    std.debug.assert(args.len >= 0);
    std.debug.assert(@TypeOf(io) == Io);
    std.debug.assert(@TypeOf(stdout) == *Io.Writer);

    // ---- argument parsing ------------------------------------------------
    var write = false;
    var object_type: ObjectType = .blob;
    var file_arg: ?[]const u8 = null;

    const args_len = @as(u32, @intCast(args.len));
    var arg_index: u32 = 0;
    while (arg_index < args_len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "-w")) {
            write = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            arg_index += 1;
            if (arg_index >= args_len) {
                try errors.print(
                    stderr,
                    "hash-object",
                    ZitError.BadUsage,
                    "-t requires a type argument",
                );
                return ZitError.BadUsage;
            }
            object_type = ObjectType.fromTypeName(args[arg_index]) catch {
                try errors.print(stderr, "hash-object", ZitError.BadUsage, args[arg_index]);
                return ZitError.BadUsage;
            };
        } else {
            file_arg = arg;
        }
    }

    const path = file_arg orelse {
        try errors.print(stderr, "hash-object", ZitError.BadUsage, "missing file argument");
        return ZitError.BadUsage;
    };

    // ---- read content ----------------------------------------------------
    const content = blk: {
        if (std.mem.eql(u8, path, "-")) {
            // Read from stdin via Io.File.
            const stdin_file: Io.File = .stdin();
            var read_buf: [4096]u8 = undefined;
            var fr: Io.File.Reader = .initStreaming(stdin_file, io, &read_buf);
            break :blk try fr.interface.allocRemaining(allocator, .unlimited);
        } else {
            const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
                try errors.print(stderr, "hash-object", err, path);
                return err;
            };
            defer file.close(io);
            var read_buf: [4096]u8 = undefined;
            var fr: Io.File.Reader = .init(file, io, &read_buf);
            break :blk try fr.interface.allocRemaining(allocator, .unlimited);
        }
    };
    defer allocator.free(content);

    // ---- compute (and optionally write) the OID --------------------------
    const oid = if (write) blk: {
        var repo = Repo.open(allocator, io) catch |err| {
            try errors.print(stderr, "hash-object", err, null);
            return err;
        };
        defer repo.deinit();
        var store = Store.init(repo.git_dir, io);
        break :blk try store.writeObject(allocator, object_type, content);
    } else Store.computeOID(object_type, content);

    try stdout.print("{f}\n", .{oid});
}
