//! Zit – public library API.
const std = @import("std");
pub const OID = @import("object/oid.zig").OID;
pub const ObjectType = @import("object/object.zig").ObjectType;
pub const Object = @import("object/object.zig").Object;
pub const Store = @import("object/store.zig").Store;
pub const Repo = @import("repo.zig").Repo;
pub const errors = @import("errors.zig");
pub const index = @import("index/index.zig");
pub const entry = @import("index/entry.zig");
pub const refs = @import("refs/store.zig");
pub const reference = @import("refs/reference.zig");

test {
    std.testing.refAllDecls(@This());
}
