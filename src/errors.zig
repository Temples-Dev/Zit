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
    InvalidOid,
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
    return switch (err) {
        Error.BadUsage => .usage,
        Error.NotAGitRepository => .repository,
        Error.ObjectNotFound, Error.CorruptObject, Error.InvalidOid => .object_store,
        else => .system,
    };
}

/// Retrieve a descriptive, user-friendly explanation of the error.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        Error.BadUsage => "Invalid command usage or arguments provided",
        Error.NotAGitRepository => "Not a git repository (or any of the parent directories)",
        Error.ObjectNotFound => "The requested Git object was not found",
        Error.CorruptObject => "The Git object is corrupt (header or size mismatch)",
        Error.InvalidOid => "The provided Object ID (OID) is invalid (must be 40-character hex)",
        std.Io.Dir.OpenError.FileNotFound => "The specified file or directory could not be found",
        std.Io.Dir.OpenError.AccessDenied => "Permission denied accessing the filesystem",
        else => @errorName(err),
    };
}

/// Print a beautifully formatted, categorized error message to the writer.
pub fn print(writer: *Io.Writer, command: []const u8, err: anyerror, context: ?[]const u8) !void {
    const category = getCategory(err);
    const explanation = explain(err);

    try writer.print("error ({s}): ", .{@tagName(category)});
    if (context) |ctx| {
        try writer.print("'{s}': ", .{ctx});
    }
    try writer.print("{s} (command: '{s}', code: {s})\n", .{
        explanation,
        command,
        @errorName(err),
    });
}
