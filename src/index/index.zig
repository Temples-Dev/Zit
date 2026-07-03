//! Git index / staging area subsystem.
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const IndexEntry = @import("entry.zig").IndexEntry;
const errors = @import("../errors.zig");
const ZitError = errors.Error;
const Io = std.Io;

/// Represents the Git index (staging area) binary file.
pub const Index = struct {
    entries: std.ArrayList(IndexEntry),

    /// Deinitializes the index and all entries, freeing name allocations.
    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        std.debug.assert(@TypeOf(allocator) == std.mem.Allocator);
        std.debug.assert(self.entries.items.len >= 0);

        for (self.entries.items) |entry| {
            allocator.free(entry.name);
        }
        self.entries.deinit(allocator);
    }

    /// Finds the index of an entry matching `path` using binary search.
    pub fn findEntryIndex(self: Index, path: []const u8) ?usize {
        std.debug.assert(path.len > 0);
        std.debug.assert(self.entries.items.len >= 0);

        var low: usize = 0;
        var high: usize = self.entries.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const mid_path = self.entries.items[mid].name;
            const ord = std.mem.order(u8, path, mid_path);
            switch (ord) {
                .lt => high = mid,
                .gt => low = mid + 1,
                .eq => return mid,
            }
        }
        return null;
    }

    /// Adds an entry to the index, keeping entries sorted by name.
    /// Replaces any existing entry with the same name.
    pub fn add(self: *Index, allocator: std.mem.Allocator, entry: IndexEntry) !void {
        std.debug.assert(@TypeOf(allocator) == std.mem.Allocator);
        std.debug.assert(entry.name.len > 0);

        if (self.findEntryIndex(entry.name)) |idx| {
            allocator.free(self.entries.items[idx].name);
            self.entries.items[idx] = entry;
        } else {
            var low: usize = 0;
            var high: usize = self.entries.items.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (std.mem.order(u8, entry.name, self.entries.items[mid].name) == .lt) {
                    high = mid;
                } else {
                    low = mid + 1;
                }
            }
            try self.entries.insert(allocator, low, entry);
        }
        std.debug.assert(self.findEntryIndex(entry.name) != null);
    }

    /// Removes an entry by path. Returns true if found and removed.
    pub fn remove(self: *Index, allocator: std.mem.Allocator, path: []const u8) bool {
        std.debug.assert(path.len > 0);
        std.debug.assert(self.entries.items.len >= 0);

        if (self.findEntryIndex(path)) |idx| {
            std.debug.assert(std.mem.eql(u8, self.entries.items[idx].name, path));
            allocator.free(self.entries.items[idx].name);
            _ = self.entries.orderedRemove(idx);
            return true;
        }
        return false;
    }

    /// Parses a single index entry from the byte slice at offset, advancing offset.
    fn parseEntry(
        allocator: std.mem.Allocator,
        file_bytes: []const u8,
        offset: *usize,
    ) !IndexEntry {
        std.debug.assert(offset.* + 62 <= file_bytes.len - 20);

        const entry_start = offset.*;
        const ctime_sec = std.mem.readInt(u32, file_bytes[offset.* .. offset.* + 4][0..4], .big);
        offset.* += 4;
        const ctime_nsec = std.mem.readInt(u32, file_bytes[offset.* .. offset.* + 4][0..4], .big);
        offset.* += 4;
        const mtime_sec = std.mem.readInt(u32, file_bytes[offset.* .. offset.* + 4][0..4], .big);
        offset.* += 4;
        const mtime_nsec = std.mem.readInt(u32, file_bytes[offset.* .. offset.* + 4][0..4], .big);
        offset.* += 4;
        const dev = std.mem.readInt(u32, file_bytes[offset.* .. offset.* + 4][0..4], .big);
        offset.* += 4;
        const ino = std.mem.readInt(u32, file_bytes[offset.* .. offset.* + 4][0..4], .big);
        offset.* += 4;
        const mode = std.mem.readInt(u32, file_bytes[offset.* .. offset.* + 4][0..4], .big);
        offset.* += 4;
        const uid = std.mem.readInt(u32, file_bytes[offset.* .. offset.* + 4][0..4], .big);
        offset.* += 4;
        const gid = std.mem.readInt(u32, file_bytes[offset.* .. offset.* + 4][0..4], .big);
        offset.* += 4;
        const size = std.mem.readInt(u32, file_bytes[offset.* .. offset.* + 4][0..4], .big);
        offset.* += 4;

        const oid_bytes = file_bytes[offset.* .. offset.* + 20];
        const oid = OID{ .bytes = oid_bytes[0..20].* };
        offset.* += 20;

        const flags = std.mem.readInt(u16, file_bytes[offset.* .. offset.* + 2][0..2], .big);
        offset.* += 2;

        const assume_valid = (flags & 0x8000) != 0;
        const stage = @as(u2, @intCast((flags & 0x3000) >> 12));
        const name_len = flags & 0x0FFF;

        // Find the NUL terminator of the path name
        var path_end = offset.*;
        while (path_end < file_bytes.len - 20 and file_bytes[path_end] != 0) : (path_end += 1) {}
        if (path_end >= file_bytes.len - 20) return ZitError.CorruptIndex;

        const pathname = file_bytes[offset.*..path_end];
        if (name_len < 0x0FFF and name_len != pathname.len) return ZitError.CorruptIndex;

        const name = try allocator.dupe(u8, pathname);
        errdefer allocator.free(name);

        const entry_len_so_far = offset.* - entry_start + pathname.len;
        std.debug.assert(entry_len_so_far == 62 + pathname.len);
        const padding_len = 8 - (entry_len_so_far % 8);

        offset.* += pathname.len + padding_len;
        if (offset.* > file_bytes.len - 20) return ZitError.CorruptIndex;

        const entry = IndexEntry{
            .ctime_sec = ctime_sec,
            .ctime_nsec = ctime_nsec,
            .mtime_sec = mtime_sec,
            .mtime_nsec = mtime_nsec,
            .dev = dev,
            .ino = ino,
            .mode = mode,
            .uid = uid,
            .gid = gid,
            .size = size,
            .oid = oid,
            .stage = stage,
            .assume_valid = assume_valid,
            .name = name,
        };
        std.debug.assert(entry.name.len == pathname.len);
        return entry;
    }

    /// Parses `.git/index` from the repository's git directory.
    pub fn parse(allocator: std.mem.Allocator, git_dir: Io.Dir, io: Io) !Index {
        std.debug.assert(@TypeOf(io) == Io);
        std.debug.assert(@TypeOf(allocator) == std.mem.Allocator);

        const file = git_dir.openFile(io, "index", .{}) catch |err| switch (err) {
            std.Io.Dir.OpenFileError.FileNotFound => {
                return Index{
                    .entries = std.ArrayList(IndexEntry).init(allocator),
                };
            },
            else => return err,
        };
        defer file.close(io);

        var read_buf: [4096]u8 = undefined;
        var fr: Io.File.Reader = .init(file, io, &read_buf);
        const file_bytes = try fr.interface.allocRemaining(allocator, .unlimited);
        defer allocator.free(file_bytes);

        if (file_bytes.len < 32) return ZitError.CorruptIndex;

        // Verify Checksum
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update(file_bytes[0 .. file_bytes.len - 20]);
        var checksum: [20]u8 = undefined;
        sha.final(&checksum);
        if (!std.mem.eql(u8, &checksum, file_bytes[file_bytes.len - 20 ..])) return ZitError.CorruptIndex;

        // Header
        if (!std.mem.eql(u8, file_bytes[0..4], "DIRC")) return ZitError.CorruptIndex;
        const version = std.mem.readInt(u32, file_bytes[4..8], .big);
        if (version != 2) return ZitError.UnsupportedIndexVersion;
        const entry_count = std.mem.readInt(u32, file_bytes[8..12], .big);

        var entries = std.ArrayList(IndexEntry).init(allocator);
        errdefer {
            for (entries.items) |entry| allocator.free(entry.name);
            entries.deinit(allocator);
        }

        var offset: usize = 12;
        var entry_idx: u32 = 0;
        while (entry_idx < entry_count) : (entry_idx += 1) {
            const entry = try parseEntry(allocator, file_bytes, &offset);
            try entries.append(allocator, entry);
        }

        const idx = Index{ .entries = entries };
        std.debug.assert(idx.entries.items.len == entry_count);
        return idx;
    }

    /// Serializes and writes the index to `.git/index` atomically.
    pub fn write(self: *const Index, allocator: std.mem.Allocator, git_dir: Io.Dir, io: Io) !void {
        std.debug.assert(@TypeOf(io) == Io);
        std.debug.assert(@TypeOf(allocator) == std.mem.Allocator);

        var lock_file = git_dir.createFile(io, "index.lock", .{ .exclusive = true }) catch |err| switch (err) {
            std.Io.Dir.CreateFileError.PathAlreadyExists => return ZitError.IndexLocked,
            else => return err,
        };
        defer {
            lock_file.close(io);
            git_dir.deleteFile(io, "index.lock") catch {};
        }

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        try buffer.appendSlice("DIRC");
        var version_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &version_buf, 2, .big);
        try buffer.appendSlice(&version_buf);

        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, @as(u32, @intCast(self.entries.items.len)), .big);
        try buffer.appendSlice(&count_buf);

        for (self.entries.items) |entry| {
            var entry_buf: [62]u8 = undefined;
            std.mem.writeInt(u32, entry_buf[0..4], entry.ctime_sec, .big);
            std.mem.writeInt(u32, entry_buf[4..8], entry.ctime_nsec, .big);
            std.mem.writeInt(u32, entry_buf[8..12], entry.mtime_sec, .big);
            std.mem.writeInt(u32, entry_buf[12..16], entry.mtime_nsec, .big);
            std.mem.writeInt(u32, entry_buf[16..20], entry.dev, .big);
            std.mem.writeInt(u32, entry_buf[20..24], entry.ino, .big);
            std.mem.writeInt(u32, entry_buf[24..28], entry.mode, .big);
            std.mem.writeInt(u32, entry_buf[28..32], entry.uid, .big);
            std.mem.writeInt(u32, entry_buf[32..36], entry.gid, .big);
            std.mem.writeInt(u32, entry_buf[36..40], entry.size, .big);
            @memcpy(entry_buf[40..60], &entry.oid.bytes);

            var flags: u16 = 0;
            if (entry.assume_valid) flags |= 0x8000;
            flags |= (@as(u16, entry.stage) & 0x03) << 12;
            const name_len = entry.name.len;
            if (name_len >= 0x0FFF) {
                flags |= 0x0FFF;
            } else {
                flags |= @as(u16, @intCast(name_len));
            }
            std.mem.writeInt(u16, entry_buf[60..62], flags, .big);

            try buffer.appendSlice(&entry_buf);
            try buffer.appendSlice(entry.name);

            const entry_len_so_far = 62 + name_len;
            const padding_len = 8 - (entry_len_so_far % 8);
            var padding_idx: u32 = 0;
            while (padding_idx < padding_len) : (padding_idx += 1) try buffer.append(0);
        }

        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update(buffer.items);
        var checksum: [20]u8 = undefined;
        sha.final(&checksum);

        var write_buf: [4096]u8 = undefined;
        var fw: Io.File.Writer = .init(lock_file, io, &write_buf);
        try fw.interface.writeAll(buffer.items);
        try fw.interface.writeAll(&checksum);
        try fw.flush();
        lock_file.close(io);

        try Io.Dir.rename(git_dir, "index.lock", git_dir, "index", io);
    }
};

test "Git index round-trip serialization and sorting" {
    const allocator = std.testing.allocator;

    var git_dir = try Io.Dir.cwd().makeOpenPath(Io.default_io, "zittest_index_git", .{});
    defer {
        git_dir.close(Io.default_io);
        Io.Dir.cwd().deleteTree(Io.default_io, "zittest_index_git") catch {};
    }

    var idx = Index{ .entries = std.ArrayList(IndexEntry).init(allocator) };
    defer idx.deinit(allocator);

    const oid = OID{ .bytes = [_]u8{1} ** 20 };

    const entry1 = IndexEntry{
        .ctime_sec = 100,
        .ctime_nsec = 200,
        .mtime_sec = 300,
        .mtime_nsec = 400,
        .dev = 5,
        .ino = 6,
        .mode = 0o100644,
        .uid = 1000,
        .gid = 1000,
        .size = 42,
        .oid = oid,
        .stage = 0,
        .assume_valid = false,
        .name = try allocator.dupe(u8, "src/main.zig"),
    };

    const entry2 = IndexEntry{
        .ctime_sec = 101,
        .ctime_nsec = 201,
        .mtime_sec = 301,
        .mtime_nsec = 401,
        .dev = 7,
        .ino = 8,
        .mode = 0o100755,
        .uid = 1001,
        .gid = 1001,
        .size = 1234,
        .oid = oid,
        .stage = 2,
        .assume_valid = true,
        .name = try allocator.dupe(u8, "build.zig"),
    };

    // Add entries (which will auto-sort: build.zig should end up before src/main.zig)
    try idx.add(allocator, entry1);
    try idx.add(allocator, entry2);

    try std.testing.expectEqual(@as(usize, 2), idx.entries.items.len);
    try std.testing.expectEqualStrings("build.zig", idx.entries.items[0].name);
    try std.testing.expectEqualStrings("src/main.zig", idx.entries.items[1].name);

    // Write to index file
    try idx.write(allocator, git_dir, Io.default_io);

    // Read back and parse
    var parsed_idx = try Index.parse(allocator, git_dir, Io.default_io);
    defer parsed_idx.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed_idx.entries.items.len);

    const read_entry2 = parsed_idx.entries.items[0];
    try std.testing.expectEqualStrings("build.zig", read_entry2.name);
    try std.testing.expectEqual(@as(u32, 101), read_entry2.ctime_sec);
    try std.testing.expectEqual(@as(u32, 7), read_entry2.dev);
    try std.testing.expectEqual(@as(u32, 0o100755), read_entry2.mode);
    try std.testing.expectEqual(@as(u2, 2), read_entry2.stage);
    try std.testing.expect(read_entry2.assume_valid);

    const read_entry1 = parsed_idx.entries.items[1];
    try std.testing.expectEqualStrings("src/main.zig", read_entry1.name);
    try std.testing.expectEqual(@as(u32, 100), read_entry1.ctime_sec);
    try std.testing.expectEqual(@as(u32, 5), read_entry1.dev);
    try std.testing.expectEqual(@as(u32, 0o100644), read_entry1.mode);
    try std.testing.expectEqual(@as(u2, 0), read_entry1.stage);
    try std.testing.expect(!read_entry1.assume_valid);
}
