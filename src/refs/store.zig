//! Git Reference Store.
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const reference_mod = @import("reference.zig");
const Reference = reference_mod.Reference;
const ReferenceType = reference_mod.ReferenceType;
const isValidRefName = reference_mod.isValidRefName;
const errors = @import("../errors.zig");
const ZitError = errors.Error;
const Io = std.Io;

pub const transaction = @import("transaction.zig");
pub const RefUpdate = transaction.RefUpdate;
pub const RefTransaction = transaction.RefTransaction;

pub const RefStore = struct {
    git_dir: Io.Dir,

    pub fn init(git_dir: Io.Dir) RefStore {
        return RefStore{ .git_dir = git_dir };
    }

    /// Recursively resolves a reference (loose or packed) to a direct OID.
    pub fn resolve(self: RefStore, allocator: std.mem.Allocator, name: []const u8, io: Io) anyerror!OID {
        std.debug.assert(name.len > 0);
        std.debug.assert(@TypeOf(io) == Io);

        // If it's a shorthand, we look up candidates.
        if (!isValidRefName(name)) {
            return self.resolveCandidate(allocator, name, io);
        }

        var current_name_buf: [256]u8 = undefined;
        var current_name: []const u8 = name;

        var depth: u32 = 0;
        while (depth < 5) : (depth += 1) {
            const ref = self.read(allocator, current_name, io) catch |err| switch (err) {
                ZitError.RefNotFound => return ZitError.RefNotFound,
                else => return err,
            };
            defer {
                switch (ref.target) {
                    .symbolic => |target| allocator.free(target),
                    else => {},
                }
            }

            switch (ref.target) {
                .direct => |oid| return oid,
                .symbolic => |target| {
                    if (!isValidRefName(target)) return ZitError.CorruptRef;
                    if (target.len >= current_name_buf.len) return ZitError.CorruptRef;
                    @memcpy(current_name_buf[0..target.len], target);
                    current_name = current_name_buf[0..target.len];
                },
            }
        }
        return ZitError.SymRefLoop;
    }

    /// Reads a reference from loose refs or packed-refs.
    pub fn read(self: RefStore, allocator: std.mem.Allocator, name: []const u8, io: Io) !Reference {
        std.debug.assert(name.len > 0);
        std.debug.assert(isValidRefName(name));

        const file = self.git_dir.openFile(io, name, .{}) catch |err| switch (err) {
            std.Io.File.OpenError.FileNotFound => {
                if (try self.readPackedRef(allocator, name, io)) |oid| {
                    return Reference{
                        .name = name,
                        .target = .{ .direct = oid },
                    };
                }
                return ZitError.RefNotFound;
            },
            else => return err,
        };
        defer file.close(io);

        var read_buf: [128]u8 = undefined;
        var fr = file.reader(io, &read_buf);
        var buf: [128]u8 = undefined;
        const bytes_read = try fr.interface.readSliceShort(&buf);
        if (bytes_read == 0) return ZitError.CorruptRef;

        return parseRefContent(allocator, name, buf[0..bytes_read]) catch return ZitError.CorruptRef;
    }

    /// Writes/updates a reference atomically using a lock file.
    pub fn write(self: RefStore, allocator: std.mem.Allocator, ref: Reference, io: Io) !void {
        std.debug.assert(ref.name.len > 0);
        std.debug.assert(isValidRefName(ref.name));

        var tx = RefTransaction.init(allocator, self);
        defer tx.deinit(allocator);

        try tx.addUpdate(allocator, RefUpdate{
            .name = ref.name,
            .new_target = ref.target,
            .old_target = null,
        });

        try tx.prepare(allocator, io);
        try tx.commit(io);
    }

    /// Deletes a loose reference file.
    pub fn delete(self: RefStore, name: []const u8, io: Io) !void {
        std.debug.assert(name.len > 0);
        std.debug.assert(isValidRefName(name));

        self.git_dir.deleteFile(io, name) catch |err| switch (err) {
            std.Io.Dir.DeleteFileError.FileNotFound => return ZitError.RefNotFound,
            else => return err,
        };
    }

    /// Resolves reference candidates for a given shorthand name.
    fn resolveCandidate(self: RefStore, allocator: std.mem.Allocator, name: []const u8, io: Io) anyerror!OID {
        var path_buf: [256]u8 = undefined;
        const prefixes = [_][]const u8{
            "refs/",
            "refs/tags/",
            "refs/heads/",
            "refs/remotes/",
        };
        for (prefixes) |prefix| {
            const candidate = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ prefix, name }) catch continue;
            if (!isValidRefName(candidate)) continue;
            if (self.resolve(allocator, candidate, io)) |oid| {
                return oid;
            } else |_| {}
        }
        const remote_head = std.fmt.bufPrint(&path_buf, "refs/remotes/{s}/HEAD", .{name}) catch return ZitError.RefNotFound;
        if (isValidRefName(remote_head)) {
            if (self.resolve(allocator, remote_head, io)) |oid| {
                return oid;
            } else |_| {}
        }
        return ZitError.RefNotFound;
    }

    /// Verifies that the reference matches the expected old target.
    pub fn verifyOldTarget(
        self: RefStore,
        allocator: std.mem.Allocator,
        name: []const u8,
        old_target: Reference.ReferenceTarget,
        io: Io,
    ) !void {
        const current = self.read(allocator, name, io) catch |err| switch (err) {
            ZitError.RefNotFound => return ZitError.RefVerifyFailed,
            else => return err,
        };
        defer {
            switch (current.target) {
                .symbolic => |target| allocator.free(target),
                else => {},
            }
        }

        const match = switch (old_target) {
            .direct => |old_oid| current.target == .direct and current.target.direct.eql(old_oid),
            .symbolic => |old_sym| current.target == .symbolic and std.mem.eql(u8, current.target.symbolic, old_sym),
        };

        if (!match) return ZitError.RefVerifyFailed;
    }

    /// Searches for a reference name in the packed-refs file.
    fn readPackedRef(self: RefStore, allocator: std.mem.Allocator, name: []const u8, io: Io) !?OID {
        _ = allocator;
        const file = self.git_dir.openFile(io, "packed-refs", .{}) catch |err| switch (err) {
            std.Io.File.OpenError.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);

        var read_buf: [1024]u8 = undefined;
        var fr: Io.File.Reader = .init(file, io, &read_buf);

        while (try fr.interface.takeDelimiter('\n')) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;

            var it = std.mem.splitScalar(u8, trimmed, ' ');
            const sha_hex = it.next() orelse continue;
            const ref_name = it.next() orelse continue;

            if (std.mem.eql(u8, ref_name, name)) {
                return try OID.fromHex(sha_hex);
            }
        }
        return null;
    }
};

fn parseRefContent(allocator: std.mem.Allocator, name: []const u8, content: []const u8) !Reference {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "ref:")) {
        const target = std.mem.trim(u8, trimmed["ref:".len..], " \t\r\n");
        return Reference{
            .name = name,
            .target = .{ .symbolic = try allocator.dupe(u8, target) },
        };
    } else {
        const oid = try OID.fromHex(trimmed);
        return Reference{
            .name = name,
            .target = .{ .direct = oid },
        };
    }
}

test "Git loose reference read/write and validation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var git_dir = try Io.Dir.cwd().createDirPathOpen(io, "zittest_refs_git", .{});
    defer {
        git_dir.close(io);
        Io.Dir.cwd().deleteTree(io, "zittest_refs_git") catch {};
    }

    // Ref validation checks
    try std.testing.expect(isValidRefName("HEAD"));
    try std.testing.expect(isValidRefName("refs/heads/main"));
    try std.testing.expect(isValidRefName("refs/tags/v1.0.0"));
    try std.testing.expect(!isValidRefName(""));
    try std.testing.expect(!isValidRefName("refs/heads/main.lock"));
    try std.testing.expect(!isValidRefName("refs/heads/.."));
    try std.testing.expect(!isValidRefName("refs/heads/foo..bar"));
    try std.testing.expect(!isValidRefName("refs/heads/foo@{bar"));

    const store = RefStore.init(git_dir);
    const oid1 = try OID.fromHex("1234567890abcdef1234567890abcdef12345678");

    // Write loose ref
    const ref1 = Reference{
        .name = "refs/heads/main",
        .target = .{ .direct = oid1 },
    };
    try store.write(allocator, ref1, io);

    // Read loose ref back
    const read_ref1 = try store.read(allocator, "refs/heads/main", io);
    try std.testing.expectEqualStrings("refs/heads/main", read_ref1.name);
    try std.testing.expect(read_ref1.target == .direct);
    try std.testing.expect(read_ref1.target.direct.eql(oid1));

    // Resolve loose ref
    const resolved_oid = try store.resolve(allocator, "refs/heads/main", io);
    try std.testing.expect(resolved_oid.eql(oid1));

    // Write symbolic ref
    const ref2 = Reference{
        .name = "HEAD",
        .target = .{ .symbolic = "refs/heads/main" },
    };
    try store.write(allocator, ref2, io);

    // Read symbolic ref back
    const read_ref2 = try store.read(allocator, "HEAD", io);
    defer allocator.free(read_ref2.target.symbolic);
    try std.testing.expectEqualStrings("HEAD", read_ref2.name);
    try std.testing.expect(read_ref2.target == .symbolic);
    try std.testing.expectEqualStrings("refs/heads/main", read_ref2.target.symbolic);

    // Resolve symbolic ref (HEAD -> refs/heads/main -> oid1)
    const resolved_head = try store.resolve(allocator, "HEAD", io);
    try std.testing.expect(resolved_head.eql(oid1));

    // Resolve candidates
    const resolved_shorthand = try store.resolve(allocator, "main", io);
    try std.testing.expect(resolved_shorthand.eql(oid1));
}

test "Git packed-refs reading and resolution" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var git_dir = try Io.Dir.cwd().createDirPathOpen(io, "zittest_packed_refs_git", .{});
    defer {
        git_dir.close(io);
        Io.Dir.cwd().deleteTree(io, "zittest_packed_refs_git") catch {};
    }

    const store = RefStore.init(git_dir);
    const oid1 = try OID.fromHex("abcdefabcdefabcdefabcdefabcdefabcdefabcd");

    // Write a dummy packed-refs file
    {
        const file = try git_dir.createFile(io, "packed-refs", .{});
        defer file.close(io);
        var write_buf: [256]u8 = undefined;
        var fw: Io.File.Writer = .init(file, io, &write_buf);
        try fw.interface.writeAll("# pack-refs with: peeled fully-peeled sorted\n");
        try fw.interface.writeAll("abcdefabcdefabcdefabcdefabcdefabcdefabcd refs/tags/v1.0.0\n");
        try fw.interface.writeAll("^7890789078907890789078907890789078907890\n");
        try fw.flush();
    }

    // Read packed ref
    const read_packed = try store.read(allocator, "refs/tags/v1.0.0", io);
    try std.testing.expectEqualStrings("refs/tags/v1.0.0", read_packed.name);
    try std.testing.expect(read_packed.target == .direct);
    try std.testing.expect(read_packed.target.direct.eql(oid1));

    // Resolve shorthand candidate
    const resolved = try store.resolve(allocator, "v1.0.0", io);
    try std.testing.expect(resolved.eql(oid1));
}
