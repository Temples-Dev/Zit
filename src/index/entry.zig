//! Git index entry representation.
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

/// A single entry in the Git index (staging area) corresponding to a file.
pub const IndexEntry = struct {
    // === Stat Cache Metadata ===
    /// Last time file metadata (like owner or permissions) changed (seconds).
    ctime_sec: u32,
    /// Last time file metadata changed (nanosecond fraction).
    ctime_nsec: u32,
    /// Last time file content was modified (seconds).
    mtime_sec: u32,
    /// Last time file content was modified (nanosecond fraction).
    mtime_nsec: u32,
    /// Device identifier containing the file.
    dev: u32,
    /// File inode number on the device.
    ino: u32,
    /// File mode (permissions and type like regular, executable, or symlink).
    mode: u32,
    /// Owner User ID.
    uid: u32,
    /// Owner Group ID.
    gid: u32,
    /// File size in bytes.
    size: u32,

    // === Object Reference ===
    /// The content Object ID (OID) pointing to the staged blob object.
    oid: OID,

    // === Git State Flags ===
    /// Merge conflict stage number (0: normal, 1: common base, 2: ours, 3: theirs).
    stage: u2,
    /// If true, Git assumes the file on disk has not changed (avoids stat calls).
    assume_valid: bool,

    // === Path ===
    /// Relative path to the file from the repository root.
    name: []const u8,

    /// Returns whether this entry matches another path.
    pub fn matchesPath(self: IndexEntry, path: []const u8) bool {
        std.debug.assert(self.name.len > 0);
        std.debug.assert(path.len > 0);

        const result = std.mem.eql(u8, self.name, path);
        return result;
    }
};
