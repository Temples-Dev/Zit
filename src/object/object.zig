//! Git object types and the bare Object container.
const std = @import("std");
const ZitError = @import("../errors.zig").Error;

/// The four fundamental Git object types.
pub const ObjectType = enum {
    blob,
    tree,
    commit,
    tag,

    /// The canonical type name used in the on-disk object header.
    pub fn typeName(self: ObjectType) []const u8 {
        std.debug.assert(@tagName(self).len > 0);
        const name = switch (self) {
            .blob => "blob",
            .tree => "tree",
            .commit => "commit",
            .tag => "tag",
        };
        std.debug.assert(name.len > 0);
        return name;
    }

    pub fn fromTypeName(s: []const u8) ZitError!ObjectType {
        std.debug.assert(s.len > 0);
        std.debug.assert(s.len < 10);

        if (std.mem.eql(u8, s, "blob")) return .blob;
        if (std.mem.eql(u8, s, "tree")) return .tree;
        if (std.mem.eql(u8, s, "commit")) return .commit;
        if (std.mem.eql(u8, s, "tag")) return .tag;
        return ZitError.UnknownObjectType;
    }
};

/// A raw Git object: its type and raw content bytes.
pub const Object = struct {
    type: ObjectType,
    data: []const u8,
};
