//! The options every rule is read with: one struct, not one per rule, so
//! adding a rule adds a field here while the CLI keeps a flat flag set.

const std = @import("std");

pub const Options = struct {
    /// Ceiling on the lines one comment block may span.
    max_comment_lines: u32 = 3,
    /// Path prefixes where the `anyopaque` token is banned; empty is off.
    no_anyopaque_paths: []const []const u8 = &.{},
    /// Files exempt from that ban, matched on a path boundary.
    no_anyopaque_allow: []const []const u8 = &.{},
};

/// The defaults, for a caller that has no flags to apply.
pub const defaults: Options = .{};

test "options: the comment-block ceiling defaults to three" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 3), defaults.max_comment_lines);
}

test "options: the anyopaque path lists default to empty, so the rule is off" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), defaults.no_anyopaque_paths.len);
    try testing.expectEqual(@as(usize, 0), defaults.no_anyopaque_allow.len);
}
