//! Git ignore file rules (.gitignore) and pattern matching.
const std = @import("std");
const errors = @import("../errors.zig");
const ZitError = errors.Error;

pub fn matchGlob(pattern: []const u8, name: []const u8) bool {
    var p_idx: usize = 0;
    var n_idx: usize = 0;
    var backtrack_p_idx: usize = 0;
    var backtrack_n_idx: usize = 0;
    var has_wildcard = false;

    while (p_idx < pattern.len or n_idx < name.len) {
        if (p_idx < pattern.len) {
            const char = pattern[p_idx];
            if (char == '*') {
                backtrack_p_idx = p_idx;
                p_idx += 1;
                backtrack_n_idx = n_idx + 1;
                has_wildcard = true;
                continue;
            } else if (char == '?') {
                if (n_idx >= name.len or name[n_idx] == '/') return false;
                p_idx += 1;
                n_idx += 1;
                continue;
            } else if (char == '[') {
                if (n_idx >= name.len or name[n_idx] == '/') return false;
                // Find closing ']'
                var close_idx = p_idx + 1;
                while (close_idx < pattern.len and pattern[close_idx] != ']') : (close_idx += 1) {}
                if (close_idx == pattern.len) {
                    // Malformed class, treat '[' as literal
                    if (name[n_idx] != '[') {
                        if (has_wildcard and backtrack_n_idx <= name.len) {
                            p_idx = backtrack_p_idx + 1;
                            n_idx = backtrack_n_idx;
                            backtrack_n_idx += 1;
                            continue;
                        }
                        return false;
                    }
                    p_idx += 1;
                    n_idx += 1;
                    continue;
                }

                const negated = (p_idx + 1 < close_idx) and (pattern[p_idx + 1] == '!' or pattern[p_idx + 1] == '^');
                const start_class = if (negated) p_idx + 2 else p_idx + 1;
                const match_char = name[n_idx];
                var class_match = false;

                var class_idx = start_class;
                while (class_idx < close_idx) {
                    if (class_idx + 2 < close_idx and pattern[class_idx + 1] == '-') {
                        const low = pattern[class_idx];
                        const high = pattern[class_idx + 2];
                        if (match_char >= low and match_char <= high) {
                            class_match = true;
                        }
                        class_idx += 3;
                    } else {
                        if (match_char == pattern[class_idx]) {
                            class_match = true;
                        }
                        class_idx += 1;
                    }
                }

                if (negated) class_match = !class_match;
                if (!class_match) {
                    if (has_wildcard and backtrack_n_idx <= name.len) {
                        p_idx = backtrack_p_idx + 1;
                        n_idx = backtrack_n_idx;
                        backtrack_n_idx += 1;
                        continue;
                    }
                    return false;
                }

                p_idx = close_idx + 1;
                n_idx += 1;
                continue;
            }
        }
        if (p_idx < pattern.len and n_idx < name.len and pattern[p_idx] == name[n_idx]) {
            p_idx += 1;
            n_idx += 1;
            continue;
        }
        // Backtrack
        if (has_wildcard and backtrack_n_idx <= name.len) {
            p_idx = backtrack_p_idx + 1;
            n_idx = backtrack_n_idx;
            backtrack_n_idx += 1;
            continue;
        }
        return false;
    }
    return true;
}

pub fn matchPath(pattern_components: []const []const u8, path_components: []const []const u8) bool {
    var p_idx: usize = 0;
    var s_idx: usize = 0;
    var backtrack_p_idx: usize = 0;
    var backtrack_s_idx: usize = 0;
    var has_wildcard = false;

    while (p_idx < pattern_components.len or s_idx < path_components.len) {
        if (p_idx < pattern_components.len) {
            const p_comp = pattern_components[p_idx];
            if (std.mem.eql(u8, p_comp, "**")) {
                backtrack_p_idx = p_idx;
                p_idx += 1;
                backtrack_s_idx = s_idx + 1;
                has_wildcard = true;
                continue;
            }
        }
        if (p_idx < pattern_components.len and s_idx < path_components.len) {
            if (matchGlob(pattern_components[p_idx], path_components[s_idx])) {
                p_idx += 1;
                s_idx += 1;
                continue;
            }
        }
        // Backtrack
        if (has_wildcard and backtrack_s_idx <= path_components.len) {
            p_idx = backtrack_p_idx + 1;
            s_idx = backtrack_s_idx;
            backtrack_s_idx += 1;
            continue;
        }
        return false;
    }
    return true;
}

fn splitPathComponents(path: []const u8, buffer: *[64][]const u8) []const []const u8 {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0) continue;
        if (count >= buffer.len) break;
        buffer[count] = component;
        count += 1;
    }
    return buffer[0..count];
}

pub const IgnoreRule = struct {
    pattern: []const u8,
    pattern_components: []const []const u8,
    is_negated: bool,
    is_dir_only: bool,
    is_anchored: bool,

    pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !?IgnoreRule {
        var trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') return null;

        var is_negated = false;
        if (trimmed[0] == '!') {
            is_negated = true;
            trimmed = trimmed[1..];
        }

        var is_dir_only = false;
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
            is_dir_only = true;
            trimmed = trimmed[0 .. trimmed.len - 1];
        }

        var is_anchored = false;
        if (trimmed.len > 0 and trimmed[0] == '/') {
            is_anchored = true;
            trimmed = trimmed[1..];
        } else if (std.mem.indexOfScalar(u8, trimmed, '/') != null) {
            is_anchored = true;
        }

        var components: []const []const u8 = &.{};
        if (is_anchored) {
            var comp_list: std.ArrayList([]const u8) = .empty;
            errdefer comp_list.deinit(allocator);
            var it = std.mem.splitScalar(u8, trimmed, '/');
            while (it.next()) |comp| {
                if (comp.len > 0) {
                    try comp_list.append(allocator, comp);
                }
            }
            components = try comp_list.toOwnedSlice(allocator);
        }

        return IgnoreRule{
            .pattern = trimmed,
            .pattern_components = components,
            .is_negated = is_negated,
            .is_dir_only = is_dir_only,
            .is_anchored = is_anchored,
        };
    }

    pub fn deinit(self: IgnoreRule, allocator: std.mem.Allocator) void {
        if (self.pattern_components.len > 0) {
            allocator.free(self.pattern_components);
        }
    }

    pub fn matches(self: IgnoreRule, path: []const u8, is_dir: bool) bool {
        if (self.is_dir_only and !is_dir) return false;

        var path_buffer: [64][]const u8 = undefined;
        const path_comps = splitPathComponents(path, &path_buffer);

        if (self.is_anchored) {
            return matchPath(self.pattern_components, path_comps);
        } else {
            for (path_comps) |comp| {
                if (matchGlob(self.pattern, comp)) return true;
            }
            return false;
        }
    }
};

pub const IgnoreFile = struct {
    base_dir: []const u8,
    content: []const u8,
    rules: []IgnoreRule,

    pub fn parse(allocator: std.mem.Allocator, base_dir: []const u8, content: []const u8) !IgnoreFile {
        const dup_base = try allocator.dupe(u8, base_dir);
        errdefer allocator.free(dup_base);
        const dup_content = try allocator.dupe(u8, content);
        errdefer allocator.free(dup_content);

        var rule_list: std.ArrayList(IgnoreRule) = .empty;
        errdefer {
            for (rule_list.items) |r| r.deinit(allocator);
            rule_list.deinit(allocator);
        }

        var it = std.mem.splitScalar(u8, dup_content, '\n');
        while (it.next()) |line| {
            if (try IgnoreRule.parse(allocator, line)) |rule| {
                try rule_list.append(allocator, rule);
            }
        }

        return IgnoreFile{
            .base_dir = dup_base,
            .content = dup_content,
            .rules = try rule_list.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: IgnoreFile, allocator: std.mem.Allocator) void {
        allocator.free(self.base_dir);
        allocator.free(self.content);
        for (self.rules) |rule| {
            rule.deinit(allocator);
        }
        allocator.free(self.rules);
    }

    pub fn matchPathRules(self: IgnoreFile, path: []const u8, is_dir: bool) ?bool {
        const rel_path = if (self.base_dir.len == 0)
            path
        else blk: {
            if (path.len == self.base_dir.len and std.mem.eql(u8, path, self.base_dir)) {
                break :blk "";
            } else if (path.len > self.base_dir.len and std.mem.startsWith(u8, path, self.base_dir) and path[self.base_dir.len] == '/') {
                break :blk path[self.base_dir.len + 1 ..];
            } else {
                return null;
            }
        };

        var result: ?bool = null;
        for (self.rules) |rule| {
            if (rule.matches(rel_path, is_dir)) {
                result = !rule.is_negated;
            }
        }
        return result;
    }
};

pub const IgnoreStack = struct {
    files: std.ArrayList(IgnoreFile),

    pub fn init(allocator: std.mem.Allocator) IgnoreStack {
        _ = allocator;
        return IgnoreStack{
            .files = .empty,
        };
    }

    pub fn deinit(self: *IgnoreStack, allocator: std.mem.Allocator) void {
        for (self.files.items) |file| {
            file.deinit(allocator);
        }
        self.files.deinit(allocator);
    }

    pub fn addIgnoreFile(self: *IgnoreStack, allocator: std.mem.Allocator, base_dir: []const u8, content: []const u8) !void {
        const file = try IgnoreFile.parse(allocator, base_dir, content);
        try self.files.append(allocator, file);
    }

    pub fn popIgnoreFile(self: *IgnoreStack, allocator: std.mem.Allocator) void {
        if (self.files.pop()) |file| {
            file.deinit(allocator);
        }
    }

    pub fn isIgnored(self: IgnoreStack, path: []const u8, is_dir: bool) bool {
        // ALWAYS ignore .git directory and everything in it
        if (std.mem.eql(u8, path, ".git") or std.mem.startsWith(u8, path, ".git/")) {
            return true;
        }

        // Check parent directories first (top-down)
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] == '/') {
                const parent = path[0..i];
                if (self.isIgnoredDirect(parent, true)) {
                    return true;
                }
            }
        }

        return self.isIgnoredDirect(path, is_dir);
    }

    fn isIgnoredDirect(self: IgnoreStack, path: []const u8, is_dir: bool) bool {
        var idx = self.files.items.len;
        while (idx > 0) {
            idx -= 1;
            const file = self.files.items[idx];
            if (file.matchPathRules(path, is_dir)) |ignored| {
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

    const path2 = [_][]const u8{"bar", "foo"};
    try std.testing.expect(!matchPath(&p1, &path2));

    // Double asterisk matching
    const p2 = [_][]const u8{"**", "foo"};
    try std.testing.expect(matchPath(&p2, &path1));
    try std.testing.expect(matchPath(&p2, &path2));

    const p3 = [_][]const u8{"a", "**", "b"};
    const path3 = [_][]const u8{"a", "b"};
    const path4 = [_][]const u8{"a", "x", "y", "b"};
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
