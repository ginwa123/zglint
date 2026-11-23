//! The options every rule is read with: one struct, not one per rule, so
//! adding a rule adds a field here while the CLI keeps a flat flag set.

const std = @import("std");

pub const Options = struct {
    /// Ceiling on the lines one comment block may span.
    max_comment_lines: u32 = 3,
    /// Ceiling on the code lines one file may carry; a comment line and a blank
    /// line are not code.
    max_file_lines: u32 = 2000,
};

/// The defaults, for a caller that has no flags to apply.
pub const defaults: Options = .{};

test "options: the comment-block ceiling defaults to three" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 3), defaults.max_comment_lines);
}

test "options: the file ceiling defaults to two thousand code lines" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 2000), defaults.max_file_lines);
}
