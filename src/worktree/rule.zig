//! Git ignore rule parsing and evaluation.
const std = @import("std");
const match = @import("match.zig");

pub const IgnoreRule = struct {
    pattern: []const u8,
    pattern_components: []const []const u8,
    is_negated: bool,
    is_dir_only: bool,
    is_anchored: bool,

    pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !?IgnoreRule {
        std.debug.assert(raw.len >= 0);
        std.debug.assert(raw.len < 65536);

        var trimmed_pattern = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed_pattern.len == 0 or trimmed_pattern[0] == '#') return null;

        var is_negated = false;
        if (trimmed_pattern[0] == '!') {
            is_negated = true;
            trimmed_pattern = trimmed_pattern[1..];
        }

        var is_dir_only = false;
        if (trimmed_pattern.len > 0 and trimmed_pattern[trimmed_pattern.len - 1] == '/') {
            is_dir_only = true;
            trimmed_pattern = trimmed_pattern[0 .. trimmed_pattern.len - 1];
        }

        var is_anchored = false;
        if (trimmed_pattern.len > 0 and trimmed_pattern[0] == '/') {
            is_anchored = true;
            trimmed_pattern = trimmed_pattern[1..];
        } else if (std.mem.indexOfScalar(u8, trimmed_pattern, '/') != null) {
            is_anchored = true;
        }

        var components: []const []const u8 = &.{};
        if (is_anchored) {
            var component_list: std.ArrayList([]const u8) = .empty;
            errdefer component_list.deinit(allocator);

            var iterator = std.mem.splitScalar(u8, trimmed_pattern, '/');
            const loop_limit = @as(u32, @intCast(trimmed_pattern.len)) + 1;
            var loop_counter: u32 = 0;
            while (iterator.next()) |component| {
                loop_counter += 1;
                if (loop_counter > loop_limit) break;

                if (component.len > 0) {
                    try component_list.append(allocator, component);
                }
            }
            components = try component_list.toOwnedSlice(allocator);
        }

        return IgnoreRule{
            .pattern = trimmed_pattern,
            .pattern_components = components,
            .is_negated = is_negated,
            .is_dir_only = is_dir_only,
            .is_anchored = is_anchored,
        };
    }

    pub fn deinit(self: IgnoreRule, allocator: std.mem.Allocator) void {
        std.debug.assert(self.pattern.len >= 0);
        std.debug.assert(self.pattern_components.len >= 0);
        if (self.pattern_components.len > 0) {
            allocator.free(self.pattern_components);
        }
    }

    pub fn matches(self: IgnoreRule, path: []const u8, is_dir: bool) bool {
        std.debug.assert(path.len >= 0);
        std.debug.assert(self.pattern.len >= 0);

        if (self.is_dir_only and !is_dir) return false;

        var path_buffer: [64][]const u8 = undefined;
        const path_components = match.splitPathComponents(path, &path_buffer);

        if (self.is_anchored) {
            return match.matchPath(self.pattern_components, path_components);
        } else {
            const loop_limit = @as(u32, @intCast(path_components.len)) + 1;
            var loop_counter: u32 = 0;
            for (path_components) |component| {
                loop_counter += 1;
                if (loop_counter > loop_limit) break;

                if (match.matchGlob(self.pattern, component)) return true;
            }
            return false;
        }
    }
};
