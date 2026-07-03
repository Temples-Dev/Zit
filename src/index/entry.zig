//! Git index entry representation.
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

/// A single entry in the Git index (staging area) corresponding to a file.
pub const IndexEntry = struct {
    ctime_sec: u32,
    ctime_nsec: u32,
    mtime_sec: u32,
    mtime_nsec: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u32,
    oid: OID,
    stage: u2,
    assume_valid: bool,
    name: []const u8,

    /// Returns whether this entry matches another path.
    pub fn matchesPath(self: IndexEntry, path: []const u8) bool {
        std.debug.assert(self.name.len > 0);
        std.debug.assert(path.len > 0);

        const result = std.mem.eql(u8, self.name, path);
        return result;
    }
};
