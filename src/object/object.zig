//! Git object types and the bare Object container.
const std = @import("std");

/// The four fundamental Git object types.
pub const ObjectType = enum {
    blob,
    tree,
    commit,
    tag,

    /// The canonical type name used in the on-disk object header.
    pub fn typeName(self: ObjectType) []const u8 {
        return switch (self) {
            .blob => "blob",
            .tree => "tree",
            .commit => "commit",
            .tag => "tag",
        };
    }

    pub fn fromTypeName(s: []const u8) error{UnknownObjectType}!ObjectType {
        if (std.mem.eql(u8, s, "blob")) return .blob;
        if (std.mem.eql(u8, s, "tree")) return .tree;
        if (std.mem.eql(u8, s, "commit")) return .commit;
        if (std.mem.eql(u8, s, "tag")) return .tag;
        return error.UnknownObjectType;
    }
};

/// A raw Git object: its type and raw content bytes.
/// `data` is owned by the allocator used to produce it; caller must free it.
pub const Object = struct {
    type: ObjectType,
    /// Raw payload — for blobs this is file data; for trees the binary
    /// tree format; for commits/tags the text header + message body.
    data: []const u8,
};
