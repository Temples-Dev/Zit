//! Git Reference Update Transaction.
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const reference_mod = @import("reference.zig");
const Reference = reference_mod.Reference;
const isValidRefName = reference_mod.isValidRefName;
const errors = @import("../errors.zig");
const ZitError = errors.Error;
const Io = std.Io;
const store_mod = @import("store.zig");
const RefStore = store_mod.RefStore;

pub const RefUpdate = struct {
    name: []const u8,
    new_target: Reference.ReferenceTarget,
    old_target: ?Reference.ReferenceTarget,
};

pub const RefTransaction = struct {
    store: RefStore,
    updates: std.ArrayList(RefUpdate),
    locked_files: std.ArrayList(LockedFile),

    const LockedFile = struct {
        name: []const u8,
        lock_file: Io.File,
        has_lock: bool,
    };

    pub fn init(allocator: std.mem.Allocator, store: RefStore) RefTransaction {
        _ = allocator;
        return RefTransaction{
            .store = store,
            .updates = .empty,
            .locked_files = .empty,
        };
    }

    pub fn deinit(self: *RefTransaction, allocator: std.mem.Allocator) void {
        for (self.updates.items) |update| {
            allocator.free(update.name);
            switch (update.new_target) {
                .symbolic => |target| allocator.free(target),
                else => {},
            }
            if (update.old_target) |old| {
                switch (old) {
                    .symbolic => |target| allocator.free(target),
                    else => {},
                }
            }
        }
        self.updates.deinit(allocator);
        for (self.locked_files.items) |lf| {
            allocator.free(lf.name);
        }
        self.locked_files.deinit(allocator);
    }

    pub fn addUpdate(self: *RefTransaction, allocator: std.mem.Allocator, update: RefUpdate) !void {
        const dup_name = try allocator.dupe(u8, update.name);
        errdefer allocator.free(dup_name);

        const dup_new_target = switch (update.new_target) {
            .direct => |oid| Reference.ReferenceTarget{ .direct = oid },
            .symbolic => |target| Reference.ReferenceTarget{ .symbolic = try allocator.dupe(u8, target) },
        };
        errdefer {
            switch (dup_new_target) {
                .symbolic => |target| allocator.free(target),
                else => {},
            }
        }

        const dup_old_target = if (update.old_target) |old| switch (old) {
            .direct => |oid| Reference.ReferenceTarget{ .direct = oid },
            .symbolic => |target| Reference.ReferenceTarget{ .symbolic = try allocator.dupe(u8, target) },
        } else null;

        try self.updates.append(allocator, RefUpdate{
            .name = dup_name,
            .new_target = dup_new_target,
            .old_target = dup_old_target,
        });
    }

    pub fn prepare(self: *RefTransaction, allocator: std.mem.Allocator, io: Io) !void {
        std.debug.assert(self.locked_files.items.len == 0);
        std.debug.assert(self.updates.items.len >= 0);

        for (self.updates.items) |update| {
            if (update.old_target) |old| {
                try self.store.verifyOldTarget(allocator, update.name, old, io);
            }

            var lock_path_buf: [256]u8 = undefined;
            const lock_path = try std.fmt.bufPrint(&lock_path_buf, "{s}.lock", .{update.name});

            if (std.mem.lastIndexOfScalar(u8, lock_path, '/')) |last_slash| {
                try self.store.git_dir.createDirPath(io, lock_path[0..last_slash]);
            }

            const lock_file = self.store.git_dir.createFile(io, lock_path, .{ .exclusive = true }) catch |err| switch (err) {
                std.Io.File.OpenError.PathAlreadyExists => {
                    self.rollback(io);
                    return ZitError.RefLocked;
                },
                else => {
                    self.rollback(io);
                    return err;
                },
            };
            errdefer lock_file.close(io);

            try self.locked_files.append(allocator, LockedFile{
                .name = try allocator.dupe(u8, update.name),
                .lock_file = lock_file,
                .has_lock = true,
            });
        }
    }

    pub fn commit(self: *RefTransaction, io: Io) !void {
        std.debug.assert(self.locked_files.items.len == self.updates.items.len);

        var idx: u32 = 0;
        errdefer self.rollback(io);

        while (idx < self.updates.items.len) : (idx += 1) {
            const update = self.updates.items[idx];
            const lf = &self.locked_files.items[idx];

            var write_buf: [128]u8 = undefined;
            var fw: Io.File.Writer = .init(lf.lock_file, io, &write_buf);

            switch (update.new_target) {
                .direct => |oid| {
                    const hex_buf = oid.toHex();
                    try fw.interface.writeAll(&hex_buf);
                    try fw.interface.writeAll("\n");
                },
                .symbolic => |target| {
                    try fw.interface.writeAll("ref: ");
                    try fw.interface.writeAll(target);
                    try fw.interface.writeAll("\n");
                },
            }
            try fw.flush();
            lf.lock_file.close(io);
            lf.has_lock = false;
        }

        var rename_idx: u32 = 0;
        while (rename_idx < self.updates.items.len) : (rename_idx += 1) {
            const update = self.updates.items[rename_idx];
            var lock_path_buf: [256]u8 = undefined;
            const lock_path = try std.fmt.bufPrint(&lock_path_buf, "{s}.lock", .{update.name});

            try Io.Dir.rename(self.store.git_dir, lock_path, self.store.git_dir, update.name, io);
        }
    }

    pub fn rollback(self: *RefTransaction, io: Io) void {
        for (self.locked_files.items) |*lf| {
            if (lf.has_lock) {
                lf.lock_file.close(io);
                lf.has_lock = false;
            }
            var lock_path_buf: [256]u8 = undefined;
            const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}.lock", .{lf.name}) catch continue;
            self.store.git_dir.deleteFile(io, lock_path) catch {};
        }
    }
};

test "Git ref transaction rollback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var git_dir = try Io.Dir.cwd().createDirPathOpen(io, "zittest_tx_git", .{});
    defer {
        git_dir.close(io);
        Io.Dir.cwd().deleteTree(io, "zittest_tx_git") catch {};
    }

    const store = RefStore.init(git_dir);
    const oid1 = try OID.fromHex("1234567890abcdef1234567890abcdef12345678");

    // Transaction old value check failure
    var tx = RefTransaction.init(allocator, store);
    defer tx.deinit(allocator);

    try tx.addUpdate(allocator, RefUpdate{
        .name = "refs/heads/main",
        .new_target = .{ .direct = oid1 },
        .old_target = .{ .direct = oid1 }, // Expected to exist/match, but doesn't exist
    });

    try std.testing.expectError(ZitError.RefVerifyFailed, tx.prepare(allocator, io));

    // Ensure no lock file remains
    var lock_exists = true;
    git_dir.access(io, "refs/heads/main.lock", .{}) catch {
        lock_exists = false;
    };
    try std.testing.expect(!lock_exists);
}
