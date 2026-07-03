//! Object Identifier — a 20-byte SHA-1 digest that uniquely names every
//! object in the Git object store.  It is the only address you need.
const std = @import("std");

const ZitError = @import("../errors.zig").Error;

pub const byte_len: u32 = 20;
pub const hex_len: u32 = 40;

/// A SHA-1 content address for a Git object.
pub const OID = struct {
    bytes: [byte_len]u8,

    pub const zero: OID = .{ .bytes = [_]u8{0} ** byte_len };

    /// Parse an `OID` from a 40-character lowercase hex string.
    pub fn fromHex(hex: []const u8) ZitError!OID {
        std.debug.assert(hex.len > 0);
        std.debug.assert(hex.len < 100);

        if (hex.len != hex_len) return ZitError.InvalidOID;
        var oid: OID = .{ .bytes = undefined };
        _ = std.fmt.hexToBytes(&oid.bytes, hex) catch return ZitError.InvalidOID;
        return oid;
    }

    /// Encode as a 40-character lowercase hex string (stack-allocated).
    pub fn toHex(self: OID) [hex_len]u8 {
        std.debug.assert(self.bytes.len == byte_len);
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        std.debug.assert(hex.len == hex_len);
        return hex;
    }

    pub fn eql(a: OID, b: OID) bool {
        std.debug.assert(a.bytes.len == byte_len);
        std.debug.assert(b.bytes.len == byte_len);
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn format(
        self: OID,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        std.debug.assert(self.bytes.len == byte_len);
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        std.debug.assert(hex.len == hex_len);

        try writer.print("{s}", .{hex});
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "OID round-trip hex encoding" {
    const hex = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
    const oid = try OID.fromHex(hex);
    try std.testing.expectEqualStrings(hex, &oid.toHex());
}

test "OID.fromHex rejects wrong length" {
    try std.testing.expectError(ZitError.InvalidOID, OID.fromHex("abc"));
    try std.testing.expectError(
        ZitError.InvalidOID,
        OID.fromHex("da39a3ee5e6b4b0d3255bfef95601890afd8070999"),
    );
}

test "OID.eql" {
    const a = try OID.fromHex("da39a3ee5e6b4b0d3255bfef95601890afd80709");
    const b = try OID.fromHex("da39a3ee5e6b4b0d3255bfef95601890afd80709");
    const c = try OID.fromHex("0000000000000000000000000000000000000000");
    try std.testing.expect(OID.eql(a, b));
    try std.testing.expect(!OID.eql(a, c));
}
