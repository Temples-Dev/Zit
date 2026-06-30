//! Git loose-object store.
//!
//! Each object lives at:
//!   <git_dir>/objects/<first-2-hex-chars>/<remaining-38-hex-chars>
//!
//! The file contents are:
//!   zlib( "<type> <byte-size>\x00" ++ raw_content )
const std = @import("std");
const Io = std.Io;
const Oid = @import("oid.zig").Oid;
const Object = @import("object.zig").Object;
const ObjectType = @import("object.zig").ObjectType;
const ZitError = @import("../errors.zig").Error;

pub const Store = struct {
    git_dir: Io.Dir,
    io: Io,

    pub fn init(git_dir: Io.Dir, io: Io) Store {
        return .{ .git_dir = git_dir, .io = io };
    }

    // -----------------------------------------------------------------------
    // OID computation (no I/O, no allocator needed)
    // -----------------------------------------------------------------------

    pub fn computeOid(object_type: ObjectType, content: []const u8) Oid {
        var hasher = std.crypto.hash.Sha1.init(.{});
        var hdr_buf: [64]u8 = undefined;
        const hdr = std.fmt.bufPrint(
            &hdr_buf,
            "{s} {d}\x00",
            .{ object_type.typeName(), content.len },
        ) catch unreachable;
        hasher.update(hdr);
        hasher.update(content);
        var oid: Oid = .{ .bytes = undefined };
        hasher.final(&oid.bytes);
        return oid;
    }

    // -----------------------------------------------------------------------
    // Write
    // -----------------------------------------------------------------------

    pub fn writeObject(
        self: *Store,
        allocator: std.mem.Allocator,
        object_type: ObjectType,
        content: []const u8,
    ) !Oid {
        const oid = computeOid(object_type, content);
        const hex = oid.toHex();
        const dir_name = hex[0..2];
        const file_name = hex[2..];

        const io = self.io;

        // Ensure objects/<xx>/ exists.
        try self.git_dir.createDirPath(io, "objects");
        var objects_dir = try self.git_dir.openDir(io, "objects", .{});
        defer objects_dir.close(io);

        try objects_dir.createDirPath(io, dir_name);
        var sub_dir = try objects_dir.openDir(io, dir_name, .{});
        defer sub_dir.close(io);

        // Idempotency: skip if already exists.
        if (sub_dir.access(io, file_name, .{})) |_| return oid else |_| {}

        // Build header.
        var hdr_buf: [64]u8 = undefined;
        const hdr = try std.fmt.bufPrint(
            &hdr_buf,
            "{s} {d}\x00",
            .{ object_type.typeName(), content.len },
        );

        // Compress.
        const compressed = try zlibCompress(allocator, hdr, content);
        defer allocator.free(compressed);

        // Atomic write.
        const tmp_name = ".tmp_obj";
        {
            const tmp_file = try sub_dir.createFile(io, tmp_name, .{});
            errdefer {
                tmp_file.close(io);
                sub_dir.deleteFile(io, tmp_name) catch {};
            }
            var write_buf: [4096]u8 = undefined;
            var fw: Io.File.Writer = .init(tmp_file, io, &write_buf);
            try fw.interface.writeAll(compressed);
            try fw.end();
            tmp_file.close(io);
        }
        try Io.Dir.rename(sub_dir, tmp_name, sub_dir, file_name, io);

        return oid;
    }

    // -----------------------------------------------------------------------
    // Read
    // -----------------------------------------------------------------------

    pub fn readObject(
        self: *Store,
        allocator: std.mem.Allocator,
        oid: Oid,
    ) !Object {
        const hex = oid.toHex();
        const dir_name = hex[0..2];
        const file_name = hex[2..];
        const io = self.io;

        var objects_dir = self.git_dir.openDir(io, "objects", .{}) catch return ZitError.ObjectNotFound;
        defer objects_dir.close(io);
        var sub_dir = objects_dir.openDir(io, dir_name, .{}) catch return ZitError.ObjectNotFound;
        defer sub_dir.close(io);
        const file = sub_dir.openFile(io, file_name, .{}) catch return ZitError.ObjectNotFound;
        defer file.close(io);

        // Read compressed data.
        var read_buf: [4096]u8 = undefined;
        var fr: Io.File.Reader = .init(file, io, &read_buf);
        const compressed = try fr.interface.allocRemaining(allocator, .unlimited);
        defer allocator.free(compressed);

        // Decompress.
        const raw = try zlibDecompress(allocator, compressed);
        defer allocator.free(raw);

        // Parse header: "<type> <size>\x00"
        const null_pos = std.mem.indexOfScalar(u8, raw, 0) orelse return ZitError.CorruptObject;
        const header = raw[0..null_pos];
        const sp = std.mem.indexOfScalar(u8, header, ' ') orelse return ZitError.CorruptObject;
        const object_type = ObjectType.fromTypeName(header[0..sp]) catch return ZitError.CorruptObject;
        const declared = std.fmt.parseInt(usize, header[sp + 1 ..], 10) catch return ZitError.CorruptObject;
        const payload = raw[null_pos + 1 ..];
        if (payload.len != declared) return ZitError.CorruptObject;

        const data = try allocator.dupe(u8, payload);
        return Object{ .type = object_type, .data = data };
    }
};

// ---------------------------------------------------------------------------
// Zlib helpers  (Zig 0.16: std.compress.flate with .zlib container)
// ---------------------------------------------------------------------------

fn zlibCompress(allocator: std.mem.Allocator, header: []const u8, content: []const u8) ![]u8 {
    const flate = std.compress.flate;

    var a = try Io.Writer.Allocating.initCapacity(allocator, 4096);
    errdefer a.deinit();

    var compress_buf: [flate.max_window_len * 2]u8 = undefined;
    var compressor = try flate.Compress.init(&a.writer, &compress_buf, .zlib, .default);

    try compressor.writer.writeAll(header);
    try compressor.writer.writeAll(content);
    try compressor.finish();

    return try allocator.dupe(u8, a.writer.buffered());
}

fn zlibDecompress(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    const flate = std.compress.flate;

    var source: Io.Reader = .fixed(compressed);
    var decomp_buf: [flate.max_window_len]u8 = undefined;
    var decompressor: flate.Decompress = .init(&source, .zlib, &decomp_buf);

    return try decompressor.reader.allocRemaining(allocator, .unlimited);
}
