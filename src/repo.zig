//! Repository discovery — walks up the filesystem from cwd to find `.git/`.
const std = @import("std");
const Io = std.Io;

const ZitError = @import("errors.zig").Error;

pub const Repo = struct {
    work_dir: Io.Dir,
    git_dir: Io.Dir,
    io: Io,

    /// Walk up from cwd until a `.git/` directory is found.
    /// Returns `ZitError.NotAGitRepository` if the root is reached without finding one.
    pub fn open(allocator: std.mem.Allocator, io: Io) !Repo {
        // Use a path-based approach: get the absolute cwd string and walk up.
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(io, &path_buf) catch return ZitError.NotAGitRepository;
        const cwd_path = path_buf[0..cwd_len];

        // Work on a mutable copy so we can truncate it.
        var dir_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        @memcpy(dir_path_buf[0..cwd_path.len], cwd_path);
        var dir_len: usize = cwd_path.len;

        while (true) {
            const search_path = dir_path_buf[0..dir_len];

            // Build ".git" path inside this directory.
            var git_check_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const git_check = std.fmt.bufPrint(&git_check_buf, "{s}/.git", .{search_path}) catch break;

            // Open the candidate work directory.
            var work_dir = Io.Dir.openDirAbsolute(io, search_path, .{}) catch break;

            if (work_dir.access(io, ".git", .{})) |_| {
                // Found it.
                const git_dir = Io.Dir.openDirAbsolute(io, git_check, .{}) catch {
                    work_dir.close(io);
                    break;
                };
                return Repo{ .work_dir = work_dir, .git_dir = git_dir, .io = io };
            } else |_| {
                work_dir.close(io);
            }

            // Stop at filesystem root.
            if (std.mem.eql(u8, search_path, "/")) break;

            // Ascend: strip the last path component.
            const parent_len = std.mem.lastIndexOfScalar(u8, search_path, '/') orelse break;
            dir_len = if (parent_len == 0) 1 else parent_len; // keep leading '/'
        }

        _ = allocator;
        return ZitError.NotAGitRepository;
    }

    pub fn deinit(self: *Repo) void {
        self.git_dir.close(self.io);
        self.work_dir.close(self.io);
    }
};
