//! Git commit object generation and serialization.
const std = @import("std");
const OID = @import("oid.zig").OID;
const Store = @import("store.zig").Store;
const Io = std.Io;

pub const Signature = struct {
    name: []const u8,
    email: []const u8,
    timestamp_seconds: i64,
    timezone: []const u8,
};

pub fn writeCommit(
    allocator: std.mem.Allocator,
    store: *Store,
    tree_oid: OID,
    parents: []const OID,
    author: Signature,
    committer: Signature,
    message: []const u8,
) !OID {
    std.debug.assert(message.len >= 0);
    std.debug.assert(parents.len >= 0);
    std.debug.assert(store.git_dir.handle >= 0);

    var commit_data = try Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer commit_data.deinit();

    const tree_hex = tree_oid.toHex();
    try commit_data.writer.print("tree {s}\n", .{tree_hex});

    const loop_limit = @as(u32, @intCast(parents.len)) + 1;
    var loop_counter: u32 = 0;
    for (parents) |parent_oid| {
        loop_counter += 1;
        if (loop_counter > loop_limit) break;

        const parent_hex = parent_oid.toHex();
        try commit_data.writer.print("parent {s}\n", .{parent_hex});
    }

    try commit_data.writer.print(
        "author {s} <{s}> {d} {s}\n",
        .{ author.name, author.email, author.timestamp_seconds, author.timezone },
    );

    try commit_data.writer.print(
        "committer {s} <{s}> {d} {s}\n",
        .{ committer.name, committer.email, committer.timestamp_seconds, committer.timezone },
    );

    try commit_data.writer.writeAll("\n");
    try commit_data.writer.writeAll(message);

    if (message.len == 0 or message[message.len - 1] != '\n') {
        try commit_data.writer.writeAll("\n");
    }

    const payload = commit_data.writer.buffered();
    const commit_oid = try store.writeObject(allocator, .commit, payload);
    return commit_oid;
}
