//! Object Identifier — a 20-byte SHA-1 digest that uniquely names every
//! object in the Git object store.  It is the only address you need.
const std = @import("std");

const ZitError = @import("../errors.zig").Error;

pub const byte_len: usize = 20;
pub const hex_len: usize = 40;

/// A SHA-1 content address for a Git object.
pub const Oid = struct {
    bytes: [byte_len]u8,

    pub const zero: Oid = .{ .bytes = [_]u8{0} ** byte_len };

    /// Parse an `Oid` from a 40-character lowercase hex string.
    pub fn fromHex(hex: []const u8) ZitError!Oid {
        if (hex.len != hex_len) return ZitError.InvalidOid;
        var oid: Oid = .{ .bytes = undefined };
        _ = std.fmt.hexToBytes(&oid.bytes, hex) catch return ZitError.InvalidOid;
        return oid;
    }

    /// Encode as a 40-character lowercase hex string (stack-allocated).
    pub fn toHex(self: Oid) [hex_len]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    pub fn eql(a: Oid, b: Oid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn format(
        self: Oid,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}", .{std.fmt.bytesToHex(self.bytes, .lower)});
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Oid round-trip hex encoding" {
    const hex = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
    const oid = try Oid.fromHex(hex);
    try std.testing.expectEqualStrings(hex, &oid.toHex());
}

test "Oid.fromHex rejects wrong length" {
    try std.testing.expectError(ZitError.InvalidOid, Oid.fromHex("abc"));
    try std.testing.expectError(ZitError.InvalidOid, Oid.fromHex("da39a3ee5e6b4b0d3255bfef95601890afd8070999"));
}

test "Oid.eql" {
    const a = try Oid.fromHex("da39a3ee5e6b4b0d3255bfef95601890afd80709");
    const b = try Oid.fromHex("da39a3ee5e6b4b0d3255bfef95601890afd80709");
    const c = try Oid.fromHex("0000000000000000000000000000000000000000");
    try std.testing.expect(Oid.eql(a, b));
    try std.testing.expect(!Oid.eql(a, c));
}
