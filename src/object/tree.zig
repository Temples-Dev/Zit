//! Git tree object generation and serialization.
const std = @import("std");
const OID = @import("oid.zig").OID;
const Store = @import("store.zig").Store;
const IndexEntry = @import("../index/entry.zig").IndexEntry;
const Io = std.Io;

pub const TreeEntry = struct {
    mode: u32,
    name: []const u8,
    oid: OID,
    is_dir: bool,
};

pub fn compareTreeEntries(context: void, a: TreeEntry, b: TreeEntry) bool {
    _ = context;
    const a_suffix = if (a.is_dir) "/" else "";
    const b_suffix = if (b.is_dir) "/" else "";

    var index: u32 = 0;
    const loop_limit = @as(u32, @intCast(a.name.len + b.name.len)) + 10;
    var loop_counter: u32 = 0;
    while (index < a.name.len or index < b.name.len) : (index += 1) {
        loop_counter += 1;
        if (loop_counter > loop_limit) break;

        const char_a = if (index < a.name.len)
            a.name[@as(usize, @intCast(index))]
        else if (index - a.name.len < a_suffix.len)
            a_suffix[@as(usize, @intCast(index - a.name.len))]
        else
            0;
        const char_b = if (index < b.name.len)
            b.name[@as(usize, @intCast(index))]
        else if (index - b.name.len < b_suffix.len)
            b_suffix[@as(usize, @intCast(index - b.name.len))]
        else
            0;

        if (char_a != char_b) {
            return char_a < char_b;
        }
    }
    return false;
}

pub fn writeTreeFromIndex(
    allocator: std.mem.Allocator,
    store: *Store,
    entries: []const IndexEntry,
) !OID {
    std.debug.assert(entries.len >= 0);
    std.debug.assert(store.git_dir.handle >= 0);

    if (entries.len == 0) {
        const oid = try store.writeObject(allocator, .tree, "");
        return oid;
    }
    const root_oid = try writeTreeRecursive(
        allocator,
        store,
        entries,
        "",
        0,
        @intCast(entries.len),
        0,
    );
    return root_oid;
}

fn writeTreeRecursive(
    allocator: std.mem.Allocator,
    store: *Store,
    entries: []const IndexEntry,
    prefix: []const u8,
    start_index: u32,
    end_index: u32,
    depth: u32,
) !OID {
    std.debug.assert(depth < 64);
    std.debug.assert(start_index <= end_index);
    std.debug.assert(end_index <= entries.len);

    var tree_entries: std.ArrayList(TreeEntry) = .empty;
    defer {
        for (tree_entries.items) |entry| {
            if (entry.is_dir) {
                allocator.free(entry.name);
            }
        }
        tree_entries.deinit(allocator);
    }

    var index = start_index;
    const loop_limit = end_index - start_index + 1;
    var loop_counter: u32 = 0;

    while (index < end_index) {
        loop_counter += 1;
        if (loop_counter > loop_limit) break;

        const index_entry = entries[index];
        std.debug.assert(index_entry.name.len > prefix.len);
        const relative_name = index_entry.name[prefix.len..];

        if (std.mem.indexOfScalar(u8, relative_name, '/')) |slash_index| {
            const subdirectory_name = relative_name[0..slash_index];

            const next_prefix = try std.fmt.allocPrint(
                allocator,
                "{s}{s}/",
                .{ prefix, subdirectory_name },
            );
            defer allocator.free(next_prefix);

            var next_index = index + 1;
            const inner_limit = end_index - index + 1;
            var inner_counter: u32 = 0;
            while (next_index < end_index) {
                inner_counter += 1;
                if (inner_counter > inner_limit) break;

                if (!std.mem.startsWith(u8, entries[next_index].name, next_prefix)) {
                    break;
                }
                next_index += 1;
            }

            const subdirectory_oid = try writeTreeRecursive(
                allocator,
                store,
                entries,
                next_prefix,
                index,
                next_index,
                depth + 1,
            );

            const duplicated_subdir_name = try allocator.dupe(u8, subdirectory_name);
            try tree_entries.append(allocator, TreeEntry{
                .mode = 0o040000,
                .name = duplicated_subdir_name,
                .oid = subdirectory_oid,
                .is_dir = true,
            });

            index = next_index;
        } else {
            try tree_entries.append(allocator, TreeEntry{
                .mode = index_entry.mode,
                .name = relative_name,
                .oid = index_entry.oid,
                .is_dir = false,
            });
            index += 1;
        }
    }

    std.sort.pdq(TreeEntry, tree_entries.items, {}, compareTreeEntries);

    var tree_data = try Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer tree_data.deinit();

    const write_limit = @as(u32, @intCast(tree_entries.items.len)) + 1;
    var write_counter: u32 = 0;
    for (tree_entries.items) |entry| {
        write_counter += 1;
        if (write_counter > write_limit) break;

        var mode_buffer: [16]u8 = undefined;
        const mode_string = std.fmt.bufPrint(&mode_buffer, "{o}", .{entry.mode}) catch unreachable;

        try tree_data.writer.print("{s} {s}\x00", .{ mode_string, entry.name });
        try tree_data.writer.writeAll(&entry.oid.bytes);
    }

    const payload = tree_data.writer.buffered();
    return try store.writeObject(allocator, .tree, payload);
}
