//! `zit commit -m <message>`
//!
//! Creates a new commit object from the current index and updates the current branch.
const std = @import("std");
const Io = std.Io;
const Repo = @import("../repo.zig").Repo;
const Store = @import("../object/store.zig").Store;
const OID = @import("../object/oid.zig").OID;
const Index = @import("../index/index.zig").Index;
const tree_mod = @import("../object/tree.zig");
const commit_mod = @import("../object/commit.zig");
const Signature = commit_mod.Signature;
const RefStore = @import("../refs/store.zig").RefStore;
const Reference = @import("../refs/reference.zig").Reference;
const errors = @import("../errors.zig");
const ZitError = errors.Error;

fn parseArguments(
    args: []const []const u8,
    message_out: *?[]const u8,
    stderr: *Io.Writer,
) !void {
    std.debug.assert(args.len >= 0);
    std.debug.assert(message_out.* == null);

    var argument_index: u32 = 0;
    const loop_limit = @as(u32, @intCast(args.len)) + 1;
    var loop_counter: u32 = 0;
    while (argument_index < args.len) {
        loop_counter += 1;
        if (loop_counter > loop_limit) break;

        const argument = args[argument_index];
        if (std.mem.eql(u8, argument, "-m")) {
            if (argument_index + 1 >= args.len) {
                try errors.print(stderr, "commit", ZitError.BadUsage, "Option -m requires a message.");
                return ZitError.BadUsage;
            }
            message_out.* = args[argument_index + 1];
            argument_index += 2;
        } else {
            try errors.print(stderr, "commit", ZitError.BadUsage, "Unknown option.");
            return ZitError.BadUsage;
        }
    }
}

fn getEnvOrDupe(
    process_environ: std.process.Environ,
    allocator: std.mem.Allocator,
    key: []const u8,
    default: []const u8,
) ![]u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(default.len > 0);

    const value = process_environ.getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return allocator.dupe(u8, default),
        else => return err,
    };
    return value;
}

fn getSignature(
    process_environ: std.process.Environ,
    allocator: std.mem.Allocator,
    role: []const u8,
    fallback_name: []const u8,
    fallback_email: []const u8,
    timestamp_seconds: i64,
) !Signature {
    std.debug.assert(role.len > 0);
    std.debug.assert(fallback_name.len > 0);

    var name_env_buf: [64]u8 = undefined;
    const name_env_key = try std.fmt.bufPrint(&name_env_buf, "GIT_{s}_NAME", .{role});
    var email_env_buf: [64]u8 = undefined;
    const email_env_key = try std.fmt.bufPrint(&email_env_buf, "GIT_{s}_EMAIL", .{role});

    const name = try getEnvOrDupe(process_environ, allocator, name_env_key, fallback_name);
    errdefer allocator.free(name);

    const email = try getEnvOrDupe(process_environ, allocator, email_env_key, fallback_email);

    return Signature{
        .name = name,
        .email = email,
        .timestamp_seconds = timestamp_seconds,
        .timezone = "+0000",
    };
}

fn updateReferenceAndPrint(
    allocator: std.mem.Allocator,
    io: Io,
    ref_store: RefStore,
    commit_oid: OID,
    parent_commits_count: usize,
    commit_message: []const u8,
    stdout: *Io.Writer,
) !void {
    std.debug.assert(commit_message.len >= 0);
    std.debug.assert(@TypeOf(stdout) == *Io.Writer);

    const head_ref = try ref_store.read(allocator, "HEAD", io);
    defer {
        switch (head_ref.target) {
            .symbolic => |target| allocator.free(target),
            else => {},
        }
    }

    const target_ref_name = switch (head_ref.target) {
        .symbolic => |target| target,
        .direct => "HEAD",
    };

    const new_ref = Reference{
        .name = target_ref_name,
        .target = .{ .direct = commit_oid },
    };
    try ref_store.write(allocator, new_ref, io);

    const first_line = blk: {
        var iterator = std.mem.splitScalar(u8, commit_message, '\n');
        break :blk iterator.first();
    };

    var branch_name: []const u8 = "HEAD";
    if (head_ref.target == .symbolic) {
        const symbolic_target = head_ref.target.symbolic;
        if (std.mem.startsWith(u8, symbolic_target, "refs/heads/")) {
            branch_name = symbolic_target["refs/heads/".len..];
        } else {
            branch_name = symbolic_target;
        }
    }

    const short_hex = commit_oid.toHex()[0..7];
    if (parent_commits_count == 0) {
        try stdout.print("[{s} (root-commit) {s}] {s}\n", .{ branch_name, short_hex, first_line });
    } else {
        try stdout.print("[{s} {s}] {s}\n", .{ branch_name, short_hex, first_line });
    }
}

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    process_environ: std.process.Environ,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    std.debug.assert(args.len >= 0);
    std.debug.assert(@TypeOf(stdout) == *Io.Writer);

    var repo = Repo.open(allocator, io) catch |err| {
        try errors.print(stderr, "commit", err, null);
        return err;
    };
    defer repo.deinit();

    var commit_message: ?[]const u8 = null;
    try parseArguments(args, &commit_message, stderr);

    if (commit_message == null or commit_message.?.len == 0) {
        try errors.print(
            stderr,
            "commit",
            ZitError.BadUsage,
            "Aborting commit due to empty commit message.",
        );
        return ZitError.BadUsage;
    }

    var index_obj = try Index.parse(allocator, repo.git_dir, io);
    defer index_obj.deinit(allocator);

    var store_obj = Store.init(repo.git_dir, io);
    const tree_oid = try tree_mod.writeTreeFromIndex(allocator, &store_obj, index_obj.entries.items);

    const ref_store = RefStore.init(repo.git_dir);
    var parent_commits: std.ArrayList(OID) = .empty;
    defer parent_commits.deinit(allocator);

    if (ref_store.resolve(allocator, "HEAD", io)) |parent_oid| {
        try parent_commits.append(allocator, parent_oid);
    } else |err| switch (err) {
        ZitError.RefNotFound => {},
        else => return err,
    }

    var timespec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &timespec);
    const commit_timestamp: i64 = timespec.sec;

    const author = try getSignature(process_environ, allocator, "AUTHOR", "Zit Author", "author@example.com", commit_timestamp);
    defer {
        allocator.free(author.name);
        allocator.free(author.email);
    }

    const committer = try getSignature(process_environ, allocator, "COMMITTER", "Zit Committer", "committer@example.com", commit_timestamp);
    defer {
        allocator.free(committer.name);
        allocator.free(committer.email);
    }

    const commit_oid = try commit_mod.writeCommit(
        allocator,
        &store_obj,
        tree_oid,
        parent_commits.items,
        author,
        committer,
        commit_message.?,
    );

    try updateReferenceAndPrint(
        allocator,
        io,
        ref_store,
        commit_oid,
        parent_commits.items.len,
        commit_message.?,
        stdout,
    );
}

test "zit commit basic flow" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const sandbox_name = "zittest_commit_sandbox";
    Io.Dir.cwd().deleteTree(io, sandbox_name) catch {};
    var sandbox_dir = try Io.Dir.cwd().createDirPathOpen(io, sandbox_name, .{});
    defer {
        sandbox_dir.close(io);
        Io.Dir.cwd().deleteTree(io, sandbox_name) catch {};
    }

    var orig_cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd_len = try std.process.currentPath(io, &orig_cwd_buf);
    const orig_cwd = orig_cwd_buf[0..orig_cwd_len];

    const sandbox_abs = try std.fs.path.resolve(allocator, &.{ orig_cwd, sandbox_name });
    defer allocator.free(sandbox_abs);

    try std.process.setCurrentPath(io, sandbox_abs);
    defer std.process.setCurrentPath(io, orig_cwd) catch {};

    var stdout_w = Io.Writer.Allocating.init(allocator);
    defer stdout_w.deinit();
    var stderr_w = Io.Writer.Allocating.init(allocator);
    defer stderr_w.deinit();

    const cmd_init = @import("init.zig");
    try cmd_init.run(allocator, io, &.{}, &stdout_w.writer);

    {
        const f1 = try sandbox_dir.createFile(io, "file1.txt", .{});
        defer f1.close(io);
        var fw = Io.File.Writer.init(f1, io, &[_]u8{});
        try fw.interface.writeAll("hello");
        try fw.end();
    }

    const cmd_add = @import("add.zig");
    try cmd_add.run(allocator, io, &.{"file1.txt"}, &stdout_w.writer, &stderr_w.writer);

    try run(allocator, io, std.process.Environ.empty, &.{ "-m", "Initial commit" }, &stdout_w.writer, &stderr_w.writer);

    var repo = try Repo.open(allocator, io);
    defer repo.deinit();

    const ref_store = RefStore.init(repo.git_dir);
    const commit_oid1 = try ref_store.resolve(allocator, "HEAD", io);

    var store = Store.init(repo.git_dir, io);
    const commit_obj1 = try store.readObject(allocator, commit_oid1);
    defer allocator.free(commit_obj1.data);

    try std.testing.expectEqual(commit_obj1.type, .commit);
    try std.testing.expect(std.mem.indexOf(u8, commit_obj1.data, "parent") == null);
    try std.testing.expect(std.mem.indexOf(u8, commit_obj1.data, "Initial commit") != null);

    {
        const f2 = try sandbox_dir.createFile(io, "file2.txt", .{});
        defer f2.close(io);
        var fw = Io.File.Writer.init(f2, io, &[_]u8{});
        try fw.interface.writeAll("world");
        try fw.end();
    }
    try cmd_add.run(allocator, io, &.{"file2.txt"}, &stdout_w.writer, &stderr_w.writer);

    try run(allocator, io, std.process.Environ.empty, &.{ "-m", "Second commit" }, &stdout_w.writer, &stderr_w.writer);

    const commit_oid2 = try ref_store.resolve(allocator, "HEAD", io);
    const commit_obj2 = try store.readObject(allocator, commit_oid2);
    defer allocator.free(commit_obj2.data);

    try std.testing.expectEqual(commit_obj2.type, .commit);

    var parent_hex_buf: [64]u8 = undefined;
    const parent_hex = std.fmt.bufPrint(&parent_hex_buf, "parent {s}", .{commit_oid1.toHex()}) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, commit_obj2.data, parent_hex) != null);
    try std.testing.expect(std.mem.indexOf(u8, commit_obj2.data, "Second commit") != null);
}
