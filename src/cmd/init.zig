//! `zit init [<directory>]`
//!
//! Creates a new Git-compatible repository skeleton:
//!
//!   .git/
//!     HEAD            ← "ref: refs/heads/main\n"
//!     config          ← minimal core config
//!     objects/        ← empty
//!     refs/heads/     ← empty
//!     refs/tags/      ← empty
const std = @import("std");
const Io = std.Io;

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const []const u8,
    stdout: *Io.Writer,
) !void {
    _ = allocator;

    // Target path argument (default: ".")
    const target: []const u8 = if (args.len > 0) args[0] else ".";

    // Resolve to absolute path.
    var abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_path = blk: {
        if (std.mem.startsWith(u8, target, "/")) {
            @memcpy(abs_buf[0..target.len], target);
            break :blk abs_buf[0..target.len];
        } else {
            var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const cwd_len = try std.process.currentPath(io, &cwd_buf);
            const cwd_path = cwd_buf[0..cwd_len];
            const joined = try std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ cwd_path, target });
            break :blk joined;
        }
    };

    // Create the target directory (ignore if it already exists).
    Io.Dir.createDirAbsolute(io, abs_path, .default_dir) catch |err| switch (err) {
        std.Io.Dir.CreateDirError.PathAlreadyExists => {},
        else => return err,
    };

    var work_dir = try Io.Dir.openDirAbsolute(io, abs_path, .{});
    defer work_dir.close(io);

    // Check for existing repo.
    if (work_dir.access(io, ".git", .{})) |_| {
        try stdout.print("Reinitialized existing Git repository in {s}/.git/\n", .{abs_path});
        return;
    } else |_| {}

    // Create .git skeleton.
    var git_dir = try work_dir.createDirPathOpen(io, ".git", .{});
    defer git_dir.close(io);

    try git_dir.createDirPath(io, "objects");
    try git_dir.createDirPath(io, "refs/heads");
    try git_dir.createDirPath(io, "refs/tags");

    // Write HEAD.
    {
        const head = try git_dir.createFile(io, "HEAD", .{});
        defer head.close(io);
        var buf: [64]u8 = undefined;
        var fw: Io.File.Writer = .init(head, io, &buf);
        try fw.interface.writeAll("ref: refs/heads/main\n");
        try fw.end();
    }

    // Write config.
    {
        const cfg = try git_dir.createFile(io, "config", .{});
        defer cfg.close(io);
        var buf: [256]u8 = undefined;
        var fw: Io.File.Writer = .init(cfg, io, &buf);
        try fw.interface.writeAll("[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n");
        try fw.end();
    }

    try stdout.print("Initialized empty Git repository in {s}/.git/\n", .{abs_path});
}
