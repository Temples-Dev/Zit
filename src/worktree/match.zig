//! Glob pattern matching algorithms.
const std = @import("std");

/// Evaluates a character class starting after the '[' in the pattern.
/// Updates pattern_index to point after the closing ']'.
/// Returns true if matched, false if not matched, null if malformed.
pub fn matchCharacterClass(
    pattern: []const u8,
    name_character: u8,
    pattern_index: *u32,
) ?bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(pattern_index.* < pattern.len);

    const start_index = pattern_index.*;
    var close_index = start_index;

    // Bound the loop to prevent infinite loops.
    const loop_limit = @as(u32, @intCast(pattern.len)) - start_index;
    var loop_counter: u32 = 0;
    while (close_index < pattern.len and pattern[close_index] != ']') : (close_index += 1) {
        loop_counter += 1;
        if (loop_counter > loop_limit) break;
    }

    if (close_index == pattern.len) {
        return null;
    }

    const is_negated = (start_index < close_index) and
        (pattern[start_index] == '!' or pattern[start_index] == '^');

    const scan_start = if (is_negated) start_index + 1 else start_index;
    var scan_index = scan_start;
    var matched = false;

    const inner_limit = close_index - scan_start;
    var inner_counter: u32 = 0;
    while (scan_index < close_index) {
        inner_counter += 1;
        if (inner_counter > inner_limit) break;

        if (scan_index + 2 < close_index and pattern[scan_index + 1] == '-') {
            const low_char = pattern[scan_index];
            const high_char = pattern[scan_index + 2];
            if (name_character >= low_char and name_character <= high_char) {
                matched = true;
            }
            scan_index += 3;
        } else {
            if (name_character == pattern[scan_index]) {
                matched = true;
            }
            scan_index += 1;
        }
    }

    pattern_index.* = close_index + 1;
    return if (is_negated) !matched else matched;
}

pub fn matchGlob(pattern: []const u8, name: []const u8) bool {
    std.debug.assert(pattern.len >= 0);
    std.debug.assert(name.len >= 0);

    var pattern_index: u32 = 0;
    var name_index: u32 = 0;
    var backtrack_pattern_index: u32 = 0;
    var backtrack_name_index: u32 = 0;
    var has_wildcard = false;

    const loop_limit = (@as(u32, @intCast(pattern.len)) + 1) * (@as(u32, @intCast(name.len)) + 1) + 100;
    var loop_counter: u32 = 0;

    while (pattern_index < pattern.len or name_index < name.len) {
        loop_counter += 1;
        if (loop_counter > loop_limit) return false;

        if (pattern_index < pattern.len) {
            const char = pattern[pattern_index];
            if (char == '*') {
                backtrack_pattern_index = pattern_index;
                pattern_index += 1;
                backtrack_name_index = name_index + 1;
                has_wildcard = true;
                continue;
            } else if (char == '?') {
                if (name_index >= name.len or name[name_index] == '/') return false;
                pattern_index += 1;
                name_index += 1;
                continue;
            } else if (char == '[') {
                if (name_index >= name.len or name[name_index] == '/') return false;

                var next_pattern_index = pattern_index + 1;
                if (matchCharacterClass(pattern, name[name_index], &next_pattern_index)) |matched| {
                    if (!matched) {
                        if (has_wildcard and backtrack_name_index <= name.len) {
                            pattern_index = backtrack_pattern_index + 1;
                            name_index = backtrack_name_index;
                            backtrack_name_index += 1;
                            continue;
                        }
                        return false;
                    }
                    pattern_index = next_pattern_index;
                    name_index += 1;
                    continue;
                } else {
                    if (name[name_index] != '[') {
                        if (has_wildcard and backtrack_name_index <= name.len) {
                            pattern_index = backtrack_pattern_index + 1;
                            name_index = backtrack_name_index;
                            backtrack_name_index += 1;
                            continue;
                        }
                        return false;
                    }
                    pattern_index += 1;
                    name_index += 1;
                    continue;
                }
            }
        }

        if (pattern_index < pattern.len and name_index < name.len and pattern[pattern_index] == name[name_index]) {
            pattern_index += 1;
            name_index += 1;
            continue;
        }

        if (has_wildcard and backtrack_name_index <= name.len) {
            pattern_index = backtrack_pattern_index + 1;
            name_index = backtrack_name_index;
            backtrack_name_index += 1;
            continue;
        }

        return false;
    }

    return true;
}

pub fn matchPath(
    pattern_components: []const []const u8,
    path_components: []const []const u8,
) bool {
    std.debug.assert(pattern_components.len >= 0);
    std.debug.assert(path_components.len >= 0);

    var pattern_index: u32 = 0;
    var path_index: u32 = 0;
    var backtrack_pattern_index: u32 = 0;
    var backtrack_path_index: u32 = 0;
    var has_wildcard = false;

    const loop_limit = (@as(u32, @intCast(pattern_components.len)) + 1) *
        (@as(u32, @intCast(path_components.len)) + 1) + 100;
    var loop_counter: u32 = 0;

    while (pattern_index < pattern_components.len or path_index < path_components.len) {
        loop_counter += 1;
        if (loop_counter > loop_limit) return false;

        if (pattern_index < pattern_components.len) {
            const pattern_component = pattern_components[pattern_index];
            if (std.mem.eql(u8, pattern_component, "**")) {
                backtrack_pattern_index = pattern_index;
                pattern_index += 1;
                backtrack_path_index = path_index + 1;
                has_wildcard = true;
                continue;
            }
        }

        if (pattern_index < pattern_components.len and path_index < path_components.len) {
            const pattern_component = pattern_components[pattern_index];
            const path_component = path_components[path_index];
            if (matchGlob(pattern_component, path_component)) {
                pattern_index += 1;
                path_index += 1;
                continue;
            }
        }

        if (has_wildcard and backtrack_path_index <= path_components.len) {
            pattern_index = backtrack_pattern_index + 1;
            path_index = backtrack_path_index;
            backtrack_path_index += 1;
            continue;
        }

        return false;
    }

    return true;
}

pub fn splitPathComponents(path: []const u8, buffer: *[64][]const u8) []const []const u8 {
    std.debug.assert(path.len >= 0);
    std.debug.assert(buffer.len == 64);

    var count: u32 = 0;
    var iterator = std.mem.splitScalar(u8, path, '/');

    const loop_limit = @as(u32, @intCast(path.len)) + 1;
    var loop_counter: u32 = 0;
    while (iterator.next()) |component| {
        loop_counter += 1;
        if (loop_counter > loop_limit) break;

        if (component.len == 0) continue;
        if (count >= buffer.len) break;

        buffer[count] = component;
        count += 1;
    }

    return buffer[0..count];
}
