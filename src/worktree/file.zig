//! Git ignore file rules list loaded from a single file.
const std = @import("std");
const rule_mod = @import("rule.zig");
const IgnoreRule = rule_mod.IgnoreRule;

pub const IgnoreFile = struct {
    base_dir: []const u8,
    content: []const u8,
    rules: []IgnoreRule,

    pub fn parse(
        allocator: std.mem.Allocator,
        base_dir: []const u8,
        content: []const u8,
    ) !IgnoreFile {
        std.debug.assert(base_dir.len >= 0);
        std.debug.assert(content.len >= 0);

        const duplicated_base_directory = try allocator.dupe(u8, base_dir);
        errdefer allocator.free(duplicated_base_directory);
        const duplicated_content = try allocator.dupe(u8, content);
        errdefer allocator.free(duplicated_content);

        var rule_list: std.ArrayList(IgnoreRule) = .empty;
        errdefer {
            const inner_limit = @as(u32, @intCast(rule_list.items.len)) + 1;
            var inner_counter: u32 = 0;
            for (rule_list.items) |rule| {
                inner_counter += 1;
                if (inner_counter > inner_limit) break;
                rule.deinit(allocator);
            }
            rule_list.deinit(allocator);
        }

        var iterator = std.mem.splitScalar(u8, duplicated_content, '\n');
        const loop_limit = @as(u32, @intCast(duplicated_content.len)) + 1;
        var loop_counter: u32 = 0;
        while (iterator.next()) |line| {
            loop_counter += 1;
            if (loop_counter > loop_limit) break;

            if (try IgnoreRule.parse(allocator, line)) |rule| {
                try rule_list.append(allocator, rule);
            }
        }

        return IgnoreFile{
            .base_dir = duplicated_base_directory,
            .content = duplicated_content,
            .rules = try rule_list.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: IgnoreFile, allocator: std.mem.Allocator) void {
        std.debug.assert(self.base_dir.len >= 0);
        std.debug.assert(self.content.len >= 0);

        allocator.free(self.base_dir);
        allocator.free(self.content);

        const loop_limit = @as(u32, @intCast(self.rules.len)) + 1;
        var loop_counter: u32 = 0;
        for (self.rules) |rule| {
            loop_counter += 1;
            if (loop_counter > loop_limit) break;
            rule.deinit(allocator);
        }
        allocator.free(self.rules);
    }

    pub fn matchPathRules(self: IgnoreFile, path: []const u8, is_dir: bool) ?bool {
        std.debug.assert(path.len >= 0);
        std.debug.assert(self.base_dir.len >= 0);

        const relative_path = if (self.base_dir.len == 0)
            path
        else blk: {
            if (path.len == self.base_dir.len and std.mem.eql(u8, path, self.base_dir)) {
                break :blk "";
            } else if (path.len > self.base_dir.len and
                std.mem.startsWith(u8, path, self.base_dir) and
                path[self.base_dir.len] == '/')
            {
                break :blk path[self.base_dir.len + 1 ..];
            } else {
                return null;
            }
        };

        var result: ?bool = null;
        const loop_limit = @as(u32, @intCast(self.rules.len)) + 1;
        var loop_counter: u32 = 0;
        for (self.rules) |rule| {
            loop_counter += 1;
            if (loop_counter > loop_limit) break;

            if (rule.matches(relative_path, is_dir)) {
                result = !rule.is_negated;
            }
        }
        return result;
    }
};
