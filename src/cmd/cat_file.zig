//! `zit cat-file (-t | -s | -p) <oid>`
//!
//!   -t   print the object type
//!   -s   print the object size in bytes
//!   -p   pretty-print the object content
const std = @import("std");
const Io = std.Io;
const Repo = @import("../repo.zig").Repo;
const Store = @import("../object/store.zig").Store;
const Oid = @import("../object/oid.zig").Oid;
const errors = @import("../errors.zig");
const ZitError = errors.Error;

const Mode = enum { type_only, size_only, pretty };

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    // ---- argument parsing ------------------------------------------------
    var mode: ?Mode = null;
    var oid_str: ?[]const u8 = null;

    for (args) |a| {
        if (std.mem.eql(u8, a, "-t")) {
            mode = .type_only;
        } else if (std.mem.eql(u8, a, "-s")) {
            mode = .size_only;
        } else if (std.mem.eql(u8, a, "-p")) {
            mode = .pretty;
        } else {
            oid_str = a;
        }
    }

    const m = mode orelse {
        try errors.print(stderr, "cat-file", ZitError.BadUsage, "missing mode (-t, -s, or -p)");
        return ZitError.BadUsage;
    };
    const hex = oid_str orelse {
        try errors.print(stderr, "cat-file", ZitError.BadUsage, "missing object ID");
        return ZitError.BadUsage;
    };

    const oid = Oid.fromHex(hex) catch |err| {
        try errors.print(stderr, "cat-file", err, hex);
        return err;
    };

    // ---- open repo + read object -----------------------------------------
    var repo = Repo.open(allocator, io) catch |err| {
        try errors.print(stderr, "cat-file", err, null);
        return err;
    };
    defer repo.deinit();

    var store = Store.init(repo.git_dir, io);
    const obj = store.readObject(allocator, oid) catch |err| {
        try errors.print(stderr, "cat-file", err, hex);
        return err;
    };
    defer allocator.free(obj.data);

    switch (m) {
        .type_only => try stdout.print("{s}\n", .{obj.type.typeName()}),
        .size_only => try stdout.print("{d}\n", .{obj.data.len}),
        .pretty => try stdout.writeAll(obj.data),
    }
}
