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
        std.debug.assert(@TypeOf(io) == Io);
        std.debug.assert(@TypeOf(allocator) == std.mem.Allocator);

        // Use a path-based approach: get the absolute cwd string and walk up.
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(io, &path_buf) catch return ZitError.NotAGitRepository;
        const cwd_path = path_buf[0..cwd_len];

        // Work on a mutable copy so we can truncate it.
        var dir_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        @memcpy(dir_path_buf[0..cwd_path.len], cwd_path);
        var dir_len: usize = cwd_path.len;

        var traversal_depth: u32 = 0;
        while (traversal_depth < 1024) : (traversal_depth += 1) {
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
                const repo = Repo{ .work_dir = work_dir, .git_dir = git_dir, .io = io };
                std.debug.assert(repo.work_dir.handle != repo.git_dir.handle);
                return repo;
            } else |_| {
                work_dir.close(io);
            }

            // Stop at filesystem root.
            if (std.mem.eql(u8, search_path, "/")) break;

            // Ascend: strip the last path component.
            const parent_len = std.mem.findScalarLast(u8, search_path, '/') orelse break;
            dir_len = if (parent_len == 0) 1 else parent_len;
        }

        return ZitError.NotAGitRepository;
    }

    pub fn deinit(self: *Repo) void {
        std.debug.assert(@TypeOf(self.io) == Io);
        std.debug.assert(self.work_dir.handle != self.git_dir.handle);

        self.git_dir.close(self.io);
        self.work_dir.close(self.io);
    }
};
