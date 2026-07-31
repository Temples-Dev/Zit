//! Git ignore file rules (.gitignore) and pattern matching.
const std = @import("std");
const match_mod = @import("match.zig");
const rule_mod = @import("rule.zig");
const file_mod = @import("file.zig");

// Re-export public API declarations to maintain package compatibility
pub const matchGlob = match_mod.matchGlob;
pub const matchPath = match_mod.matchPath;
pub const splitPathComponents = match_mod.splitPathComponents;
pub const IgnoreRule = rule_mod.IgnoreRule;
pub const IgnoreFile = file_mod.IgnoreFile;

pub const IgnoreStack = struct {
    files: std.ArrayList(IgnoreFile),

    pub fn init(allocator: std.mem.Allocator) IgnoreStack {
        _ = allocator;
        const stack = IgnoreStack{
            .files = .empty,
        };
        std.debug.assert(stack.files.items.len == 0);
        std.debug.assert(stack.files.capacity == 0);
        return stack;
    }

    pub fn deinit(self: *IgnoreStack, allocator: std.mem.Allocator) void {
        std.debug.assert(self.files.items.len >= 0);
        std.debug.assert(self.files.capacity >= 0);

        const loop_limit = @as(u32, @intCast(self.files.items.len)) + 1;
        var loop_counter: u32 = 0;
        for (self.files.items) |ignore_file| {
            loop_counter += 1;
            if (loop_counter > loop_limit) break;
            ignore_file.deinit(allocator);
        }
        self.files.deinit(allocator);
    }

    pub fn addIgnoreFile(
        self: *IgnoreStack,
        allocator: std.mem.Allocator,
        base_dir: []const u8,
        content: []const u8,
    ) !void {
        std.debug.assert(base_dir.len >= 0);
        std.debug.assert(content.len >= 0);

        const ignore_file = try IgnoreFile.parse(allocator, base_dir, content);
        try self.files.append(allocator, ignore_file);
    }

    pub fn popIgnoreFile(self: *IgnoreStack, allocator: std.mem.Allocator) void {
        std.debug.assert(self.files.items.len >= 0);
        std.debug.assert(self.files.capacity >= 0);

        if (self.files.pop()) |ignore_file| {
            ignore_file.deinit(allocator);
        }
    }

    pub fn isIgnored(self: IgnoreStack, path: []const u8, is_dir: bool) bool {
        std.debug.assert(path.len >= 0);
        std.debug.assert(self.files.items.len >= 0);

        // ALWAYS ignore .git directory and everything in it.
        if (std.mem.eql(u8, path, ".git") or std.mem.startsWith(u8, path, ".git/")) {
            return true;
        }

        // Check parent directories first (top-down).
        var char_index: u32 = 0;
        const loop_limit = @as(u32, @intCast(path.len)) + 1;
        var loop_counter: u32 = 0;
        while (char_index < path.len) : (char_index += 1) {
            loop_counter += 1;
            if (loop_counter > loop_limit) break;

            if (path[@as(usize, @intCast(char_index))] == '/') {
                const parent = path[0..@as(usize, @intCast(char_index))];
                if (self.isIgnoredDirect(parent, true)) {
                    return true;
                }
            }
        }

        return self.isIgnoredDirect(path, is_dir);
    }

    fn isIgnoredDirect(self: IgnoreStack, path: []const u8, is_dir: bool) bool {
        std.debug.assert(path.len >= 0);
        std.debug.assert(self.files.items.len >= 0);

        var file_index = @as(u32, @intCast(self.files.items.len));
        const loop_limit = file_index + 1;
        var loop_counter: u32 = 0;
        while (file_index > 0) {
            loop_counter += 1;
            if (loop_counter > loop_limit) break;

            file_index -= 1;
            const ignore_file = self.files.items[@as(usize, @intCast(file_index))];
            if (ignore_file.matchPathRules(path, is_dir)) |ignored| {
                return ignored;
            }
        }
        return false;
    }
};

test "Gitignore glob matching" {
    // Standard wildcards
    try std.testing.expect(matchGlob("*.c", "main.c"));
    try std.testing.expect(!matchGlob("*.c", "main.h"));
    try std.testing.expect(matchGlob("temp?", "tempa"));
    try std.testing.expect(!matchGlob("temp?", "tempaa"));

    // Character classes
    try std.testing.expect(matchGlob("file[1-3].txt", "file2.txt"));
    try std.testing.expect(!matchGlob("file[1-3].txt", "file4.txt"));
    try std.testing.expect(matchGlob("file[!a-z].txt", "file1.txt"));
    try std.testing.expect(!matchGlob("file[!a-z].txt", "filea.txt"));
}

test "Gitignore path component matching" {
    // Anchored patterns
    const p1 = [_][]const u8{"foo"};
    const path1 = [_][]const u8{"foo"};
    try std.testing.expect(matchPath(&p1, &path1));

    const path2 = [_][]const u8{ "bar", "foo" };
    try std.testing.expect(!matchPath(&p1, &path2));

    // Double asterisk matching
    const p2 = [_][]const u8{ "**", "foo" };
    try std.testing.expect(matchPath(&p2, &path1));
    try std.testing.expect(matchPath(&p2, &path2));

    const p3 = [_][]const u8{ "a", "**", "b" };
    const path3 = [_][]const u8{ "a", "b" };
    const path4 = [_][]const u8{ "a", "x", "y", "b" };
    try std.testing.expect(matchPath(&p3, &path3));
    try std.testing.expect(matchPath(&p3, &path4));
}

test "IgnoreStack nested files and precedence" {
    const allocator = std.testing.allocator;
    var stack = IgnoreStack.init(allocator);
    defer stack.deinit(allocator);

    // Root gitignore: ignore all .o files and temp/ directory
    try stack.addIgnoreFile(allocator, "", "*.o\ntemp/\n");

    try std.testing.expect(stack.isIgnored("main.o", false));
    try std.testing.expect(stack.isIgnored("src/main.o", false));
    try std.testing.expect(stack.isIgnored("temp/file.txt", false));
    try std.testing.expect(!stack.isIgnored("main.c", false));

    // Subdirectory gitignore: un-ignore main.o under src/
    try stack.addIgnoreFile(allocator, "src", "!main.o\n");

    try std.testing.expect(!stack.isIgnored("src/main.o", false));
    try std.testing.expect(stack.isIgnored("main.o", false)); // still ignored in root
}
