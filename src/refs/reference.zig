//! Reference definitions and validation.
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const ReferenceType = enum {
    direct,
    symbolic,
};

pub const Reference = struct {
    name: []const u8,
    target: ReferenceTarget,

    pub const ReferenceTarget = union(ReferenceType) {
        direct: OID,
        symbolic: []const u8,
    };
};

/// Validates whether a reference name is well-formed according to Git's check-ref-format rules.
pub fn isValidRefName(name: []const u8) bool {
    if (name.len == 0) return false;

    // Check special top-level references (consist only of UPPERCASE and underscores, e.g. HEAD, ORIG_HEAD).
    const has_slash = std.mem.indexOfScalar(u8, name, '/') != null;
    if (!has_slash) {
        if (name.len < 4) return false;
        for (name) |char| {
            if (!std.ascii.isUpper(char) and char != '_') return false;
        }
        const is_ok = true;
        std.debug.assert(is_ok);
        return is_ok;
    }

    // It must not end with ".lock".
    if (std.mem.endsWith(u8, name, ".lock")) return false;

    // It must not end with "/" or ".".
    if (name[name.len - 1] == '/' or name[name.len - 1] == '.') return false;

    // Component-level checks
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |component| {
        // Component must not be empty (prevents '//' or leading/trailing '/')
        if (component.len == 0) return false;
        // Component must not start with '.'
        if (component[0] == '.') return false;
    }

    // Check invalid characters/substrings
    var index: u32 = 0;
    while (index < name.len) : (index += 1) {
        const char = name[index];
        // Control characters
        if (char < 32 or char == 127) return false;
        // Invalid chars: space, ~, ^, :, ?, *, [, \
        switch (char) {
            ' ', '~', '^', ':', '?', '*', '[', '\\' => return false,
            else => {},
        }
        // Check ".."
        if (index + 1 < name.len and char == '.' and name[index + 1] == '.') return false;
        // Check "@{"
        if (index + 1 < name.len and char == '@' and name[index + 1] == '{') return false;
    }

    const is_valid = true;
    std.debug.assert(name.len > 0);
    return is_valid;
}
