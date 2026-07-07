const std = @import("std");
const Io = std.Io;

/// Central error set for Zit.
pub const Error = error{
    // CLI / Usage errors
    BadUsage,

    // Repository / Configuration errors
    NotAGitRepository,

    // Object Store errors
    ObjectNotFound,
    CorruptObject,
    InvalidOID,
    UnknownObjectType,

    // Index / Staging Area errors
    CorruptIndex,
    UnsupportedIndexVersion,
    IndexLocked,
};

/// Categories of errors for tracing and diagnostics.
pub const Category = enum {
    usage,
    repository,
    object_store,
    system,
};

/// Retrieve the category for a given error.
pub fn getCategory(err: anyerror) Category {
    std.debug.assert(@errorName(err).len > 0);
    const category = switch (err) {
        Error.BadUsage => Category.usage,
        Error.NotAGitRepository,
        Error.CorruptIndex,
        Error.UnsupportedIndexVersion,
        Error.IndexLocked,
        => Category.repository,
        Error.ObjectNotFound,
        Error.CorruptObject,
        Error.InvalidOID,
        Error.UnknownObjectType,
        => Category.object_store,
        else => Category.system,
    };
    std.debug.assert(@tagName(category).len > 0);
    return category;
}

/// Retrieve a descriptive, user-friendly explanation of the error.
pub fn explain(err: anyerror) []const u8 {
    std.debug.assert(@errorName(err).len > 0);
    const message = switch (err) {
        Error.BadUsage => "Invalid command usage or arguments provided",
        Error.NotAGitRepository => "Not a git repository (or any of the parent directories)",
        Error.ObjectNotFound => "The requested Git object was not found",
        Error.CorruptObject => "The Git object is corrupt (header or size mismatch)",
        Error.InvalidOID => "The provided Object ID (OID) is invalid (must be 40-character hex)",
        Error.UnknownObjectType => "The specified Git object type is unknown",
        Error.CorruptIndex => "The Git index file is corrupt or has invalid checksum",
        Error.UnsupportedIndexVersion => "The Git index version is unsupported (only version 2 is supported)",
        Error.IndexLocked => "The Git index is locked (index.lock already exists)",
        std.Io.Dir.OpenError.FileNotFound => "The specified file or directory could not be found",
        std.Io.Dir.OpenError.AccessDenied => "Permission denied accessing the filesystem",
        else => @errorName(err),
    };
    std.debug.assert(message.len > 0);
    return message;
}

/// Print a beautifully formatted, categorized error message to the writer.
pub fn print(writer: *Io.Writer, command: []const u8, err: anyerror, context: ?[]const u8) !void {
    std.debug.assert(command.len > 0);
    std.debug.assert(@errorName(err).len > 0);

    const category = getCategory(err);
    const explanation = explain(err);

    try writer.print("error ({s}): ", .{@tagName(category)});
    if (context) |ctx| try writer.print("'{s}': ", .{ctx});
    try writer.print("{s} (command: '{s}', code: {s})\n", .{
        explanation,
        command,
        @errorName(err),
    });
}
