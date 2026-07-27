//! `zit add <pathspec>...`
//!
//! Stages files by writing blobs to the object store and updating the index.
const std = @import("std");
const Io = std.Io;
const Repo = @import("../repo.zig").Repo;
const Store = @import("../object/store.zig").Store;
const Index = @import("../index/index.zig").Index;
const IndexEntry = @import("../index/entry.zig").IndexEntry;
const IgnoreStack = @import("../worktree/ignore.zig").IgnoreStack;
const errors = @import("../errors.zig");
const ZitError = errors.Error;

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    _ = stdout;
    std.debug.assert(args.len >= 0);
    std.debug.assert(@TypeOf(io) == Io);

    if (args.len == 0) {
        try errors.print(stderr, "add", ZitError.BadUsage, "Nothing specified, nothing added.");
        return ZitError.BadUsage;
    }

    var repo = Repo.open(allocator, io) catch |err| {
        try errors.print(stderr, "add", err, null);
        return err;
    };
    defer repo.deinit();

    const repo_root_abs = try getRepoRootAbs(allocator, io);
    defer allocator.free(repo_root_abs);

    var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd_abs = cwd_buf[0..cwd_len];

    var index = try Index.parse(allocator, repo.git_dir, io);
    defer index.deinit(allocator);

    var ignore_stack = IgnoreStack.init(allocator);
    defer ignore_stack.deinit(allocator);

    for (args) |path_arg| {
        const abs_path = try std.fs.path.resolve(allocator, &.{ cwd_abs, path_arg });
        defer allocator.free(abs_path);

        const rel_path = if (std.mem.eql(u8, abs_path, repo_root_abs))
            ""
        else if (std.mem.startsWith(u8, abs_path, repo_root_abs) and abs_path[repo_root_abs.len] == '/')
            abs_path[repo_root_abs.len + 1 ..]
        else {
            try stderr.print("fatal: pathspec '{s}' is outside repository\n", .{path_arg});
            return ZitError.BadUsage;
        };

        var is_dir = false;
        var exists = true;

        if (Io.Dir.openDirAbsolute(io, abs_path, .{ .iterate = true })) |dir| {
            dir.close(io);
            is_dir = true;
        } else |err| switch (err) {
            else => {
                if (Io.Dir.openFileAbsolute(io, abs_path, .{ .follow_symlinks = false })) |file| {
                    file.close(io);
                } else |open_err| switch (open_err) {
                    std.Io.File.OpenError.FileNotFound => {
                        exists = false;
                    },
                    else => return open_err,
                }
            },
        }

        if (!exists) {
            if (index.remove(allocator, rel_path)) {
                // Successfully staged deletion of the file
                continue;
            } else {
                try errors.print(stderr, "add", std.Io.Dir.OpenError.FileNotFound, path_arg);
                return std.Io.Dir.OpenError.FileNotFound;
            }
        }

        // Reset ignore stack for this pathspec, then load all ignores up to it
        ignore_stack.deinit(allocator);
        ignore_stack = IgnoreStack.init(allocator);
        try loadIgnoresForPath(allocator, io, &repo, rel_path, &ignore_stack);

        if (is_dir) {
            var dir = try Io.Dir.openDirAbsolute(io, abs_path, .{ .iterate = true });
            defer dir.close(io);

            var walker = try Io.Dir.walkSelectively(dir, allocator);
            defer walker.deinit();

            while (try walker.next(io)) |entry| {
                const entry_abs = try std.fs.path.resolve(allocator, &.{ abs_path, entry.path });
                defer allocator.free(entry_abs);

                const entry_rel = if (std.mem.eql(u8, entry_abs, repo_root_abs))
                    ""
                else
                    entry_abs[repo_root_abs.len + 1 ..];

                const last_slash = std.mem.findScalarLast(u8, entry_rel, '/');
                const entry_dir = if (last_slash) |idx| entry_rel[0..idx] else "";

                try syncIgnoreStack(allocator, io, &repo, entry_dir, &ignore_stack);

                if (entry.kind == .directory) {
                    if (ignore_stack.isIgnored(entry_rel, true)) {
                        // Skip entering ignored directories
                    } else {
                        try walker.enter(io, entry);
                        try loadIgnoreFile(allocator, io, &repo, entry_rel, &ignore_stack);
                    }
                } else {
                    if (!ignore_stack.isIgnored(entry_rel, false)) {
                        try stageFile(allocator, io, &repo, &index, entry_rel);
                    }
                }
            }
        } else {
            if (ignore_stack.isIgnored(rel_path, false)) {
                try stderr.print("fatal: pathspec '{s}' is in gitignore\n", .{path_arg});
                return ZitError.BadUsage;
            }
            try stageFile(allocator, io, &repo, &index, rel_path);
        }
    }

    try index.write(allocator, repo.git_dir, io);
}

fn getRepoRootAbs(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &path_buf);
    const cwd_path = path_buf[0..cwd_len];

    var dir_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    @memcpy(dir_path_buf[0..cwd_path.len], cwd_path);
    var dir_len: u32 = @as(u32, @intCast(cwd_path.len));

    var traversal_depth: u32 = 0;
    while (traversal_depth < 1024) : (traversal_depth += 1) {
        const search_path = dir_path_buf[0..dir_len];
        var work_dir = Io.Dir.openDirAbsolute(io, search_path, .{}) catch break;
        defer work_dir.close(io);

        if (work_dir.access(io, ".git", .{})) |_| {
            return try allocator.dupe(u8, search_path);
        } else |_| {}

        if (std.mem.eql(u8, search_path, "/")) break;
        const parent_len = std.mem.findScalarLast(u8, search_path, '/') orelse break;
        dir_len = if (parent_len == 0) 1 else @as(u32, @intCast(parent_len));
    }
    return ZitError.NotAGitRepository;
}

fn loadIgnoresForPath(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *Repo,
    rel_path: []const u8,
    ignore_stack: *IgnoreStack,
) !void {
    try loadIgnoreFile(allocator, io, repo, "", ignore_stack);

    var it = std.mem.splitScalar(u8, rel_path, '/');
    var path_accum: std.ArrayList(u8) = .empty;
    defer path_accum.deinit(allocator);

    while (it.next()) |comp| {
        if (it.peek() == null) break;

        if (path_accum.items.len > 0) {
            try path_accum.append(allocator, '/');
        }
        try path_accum.appendSlice(allocator, comp);
        try loadIgnoreFile(allocator, io, repo, path_accum.items, ignore_stack);
    }
}

fn loadIgnoreFile(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *Repo,
    base_dir: []const u8,
    ignore_stack: *IgnoreStack,
) !void {
    for (ignore_stack.files.items) |file| {
        if (std.mem.eql(u8, file.base_dir, base_dir)) return;
    }

    const gitignore_name = if (base_dir.len == 0)
        ".gitignore"
    else
        try std.fs.path.join(allocator, &.{ base_dir, ".gitignore" });
    defer if (base_dir.len > 0) allocator.free(gitignore_name);

    var file = repo.work_dir.openFile(io, gitignore_name, .{}) catch |err| switch (err) {
        std.Io.File.OpenError.FileNotFound => return,
        else => return err,
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var fr: Io.File.Reader = .init(file, io, &read_buf);
    const content = try fr.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(content);

    try ignore_stack.addIgnoreFile(allocator, base_dir, content);
}

fn syncIgnoreStack(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *Repo,
    target_dir: []const u8,
    ignore_stack: *IgnoreStack,
) !void {
    while (ignore_stack.files.items.len > 0) {
        const top_file = ignore_stack.files.items[ignore_stack.files.items.len - 1];
        if (top_file.base_dir.len == 0) {
            break;
        }
        const is_parent = if (std.mem.startsWith(u8, target_dir, top_file.base_dir)) blk: {
            if (target_dir.len == top_file.base_dir.len) {
                break :blk true;
            } else {
                break :blk target_dir[top_file.base_dir.len] == '/';
            }
        } else false;

        if (!is_parent) {
            ignore_stack.popIgnoreFile(allocator);
        } else {
            break;
        }
    }

    if (target_dir.len > 0) {
        var it = std.mem.splitScalar(u8, target_dir, '/');
        var path_accum: std.ArrayList(u8) = .empty;
        defer path_accum.deinit(allocator);

        while (it.next()) |comp| {
            if (path_accum.items.len > 0) {
                try path_accum.append(allocator, '/');
            }
            try path_accum.appendSlice(allocator, comp);
            try loadIgnoreFile(allocator, io, repo, path_accum.items, ignore_stack);
        }
    }
}

fn stageFile(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *Repo,
    index: *Index,
    rel_path: []const u8,
) !void {
    var stat: Io.File.Stat = undefined;
    const content = blk: {
        var file = try repo.work_dir.openFile(io, rel_path, .{ .follow_symlinks = false });
        defer file.close(io);
        stat = try file.stat(io);

        if (stat.kind == .sym_link) {
            var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const link_len = try repo.work_dir.readLink(io, rel_path, &link_buf);
            break :blk try allocator.dupe(u8, link_buf[0..link_len]);
        } else {
            var read_buf: [4096]u8 = undefined;
            var fr: Io.File.Reader = .init(file, io, &read_buf);
            break :blk try fr.interface.allocRemaining(allocator, .unlimited);
        }
    };
    defer allocator.free(content);

    var store = Store.init(repo.git_dir, repo.io);
    const oid = try store.writeObject(allocator, .blob, content);

    var mode: u32 = 0o100644;
    if (stat.kind == .sym_link) {
        mode = 0o120000;
    } else if (stat.kind == .file) {
        if (@hasDecl(std.Io.File.Permissions, "toMode")) {
            const p_mode = stat.permissions.toMode();
            if ((p_mode & 0o111) != 0) {
                mode = 0o100755;
            }
        }
    }

    const entry = IndexEntry{
        .ctime_sec = @intCast(stat.ctime.toSeconds()),
        .ctime_nsec = @intCast(@mod(stat.ctime.toNanoseconds(), 1_000_000_000)),
        .mtime_sec = @intCast(stat.mtime.toSeconds()),
        .mtime_nsec = @intCast(@mod(stat.mtime.toNanoseconds(), 1_000_000_000)),
        .dev = 0,
        .ino = @as(u32, @truncate(stat.inode)),
        .mode = mode,
        .uid = 0,
        .gid = 0,
        .size = @as(u32, @truncate(stat.size)),
        .oid = oid,
        .stage = 0,
        .assume_valid = false,
        .name = try allocator.dupe(u8, rel_path),
    };

    try index.add(allocator, entry);
}

test "zit add staging and gitignore behavior" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const sandbox_name = "zittest_add_sandbox";
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

    try sandbox_dir.access(io, ".git", .{});

    {
        const f1 = try sandbox_dir.createFile(io, "file1.txt", .{});
        defer f1.close(io);
        var fw = Io.File.Writer.init(f1, io, &[_]u8{});
        try fw.interface.writeAll("hello");
        try fw.end();
    }
    try sandbox_dir.createDirPath(io, "src");
    {
        const f2 = try sandbox_dir.createFile(io, "src/file2.txt", .{});
        defer f2.close(io);
        var fw = Io.File.Writer.init(f2, io, &[_]u8{});
        try fw.interface.writeAll("world");
        try fw.end();
    }
    {
        const f3 = try sandbox_dir.createFile(io, "src/ignored.txt", .{});
        defer f3.close(io);
        var fw = Io.File.Writer.init(f3, io, &[_]u8{});
        try fw.interface.writeAll("should be ignored");
        try fw.end();
    }
    {
        const f4 = try sandbox_dir.createFile(io, "test.log", .{});
        defer f4.close(io);
        var fw = Io.File.Writer.init(f4, io, &[_]u8{});
        try fw.interface.writeAll("log file");
        try fw.end();
    }
    {
        const gi = try sandbox_dir.createFile(io, ".gitignore", .{});
        defer gi.close(io);
        var fw = Io.File.Writer.init(gi, io, &[_]u8{});
        try fw.interface.writeAll("ignored.txt\n*.log\n");
        try fw.end();
    }

    try run(allocator, io, &.{ "file1.txt", "src" }, &stdout_w.writer, &stderr_w.writer);

    var repo = try Repo.open(allocator, io);
    defer repo.deinit();

    var index = try Index.parse(allocator, repo.git_dir, io);
    defer index.deinit(allocator);

    try std.testing.expect(index.findEntryIndex("file1.txt") != null);
    try std.testing.expect(index.findEntryIndex("src/file2.txt") != null);
    try std.testing.expect(index.findEntryIndex("src/ignored.txt") == null);
    try std.testing.expect(index.findEntryIndex("test.log") == null);

    const entry1 = index.entries.items[index.findEntryIndex("file1.txt").?];
    const entry2 = index.entries.items[index.findEntryIndex("src/file2.txt").?];

    var store = Store.init(repo.git_dir, io);
    const obj1 = try store.readObject(allocator, entry1.oid);
    defer allocator.free(obj1.data);
    try std.testing.expectEqual(obj1.type, .blob);
    try std.testing.expectEqualStrings("hello", obj1.data);

    const obj2 = try store.readObject(allocator, entry2.oid);
    defer allocator.free(obj2.data);
    try std.testing.expectEqual(obj2.type, .blob);
    try std.testing.expectEqualStrings("world", obj2.data);

    try sandbox_dir.deleteFile(io, "file1.txt");

    try run(allocator, io, &.{ "file1.txt" }, &stdout_w.writer, &stderr_w.writer);

    var index2 = try Index.parse(allocator, repo.git_dir, io);
    defer index2.deinit(allocator);

    try std.testing.expect(index2.findEntryIndex("file1.txt") == null);
    try std.testing.expect(index2.findEntryIndex("src/file2.txt") != null);
}
