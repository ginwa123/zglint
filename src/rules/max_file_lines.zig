//! `zginlint/max-file-lines`: one file may not carry more than N code lines.
//! Blank lines and comment lines do not count; the finding lands on the first
//! line past the ceiling.

const std = @import("std");
const comment_scan = @import("../comment_scan.zig");
const rule = @import("../rule.zig");

pub const id = "zginlint/max-file-lines";

pub const declaration = rule.Rule{
    .id = id,
    .fingerprint = fingerprint,
    .check = check,
};

pub fn fingerprint(allocator: std.mem.Allocator, options: rule.Options) ![]u8 {
    return std.fmt.allocPrint(allocator, "max={d}", .{options.max_file_lines});
}

/// Append one diagnostic when the file is over the ceiling.
pub fn check(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: rule.Options,
    out: *std.ArrayList(rule.Diagnostic),
) anyerror!void {
    const measured = try measure(allocator, source, options.max_file_lines);
    if (measured.first_over == 0) return;

    const message = try std.fmt.allocPrint(
        allocator,
        "File has {d} code lines; max is {d}",
        .{ measured.code, options.max_file_lines },
    );
    errdefer allocator.free(message);
    try out.append(allocator, .{
        .rule_id = id,
        .line = measured.first_over,
        .message = message,
    });
}

pub const Measured = struct {
    /// How many lines carry content that is not a comment.
    code: u32 = 0,
    /// 1-based line of the first code line past the ceiling, 0 when under.
    first_over: u32 = 0,
};

/// Count the code lines of `source`, remembering where it crossed `ceiling`.
pub fn measure(allocator: std.mem.Allocator, source: []const u8, ceiling: u32) !Measured {
    const comment_lines = try comment_scan.commentLines(allocator, source);
    defer allocator.free(comment_lines);

    var measured: Measured = .{};
    var comment_index: usize = 0;
    var line_number: u32 = 1;
    var rest = source;

    while (true) {
        const newline = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..newline];

        var is_comment = false;
        if (comment_index < comment_lines.len and comment_lines[comment_index] == line_number) {
            is_comment = true;
            comment_index += 1;
        }

        if (!is_comment and std.mem.trim(u8, line, " \t\r").len > 0) {
            measured.code += 1;
            if (measured.first_over == 0 and measured.code > ceiling) measured.first_over = line_number;
        }

        if (newline == rest.len) break;
        rest = rest[newline + 1 ..];
        line_number += 1;
    }

    return measured;
}

const testing = std.testing;

fn findings(source: []const u8, options: rule.Options) !std.ArrayList(rule.Diagnostic) {
    var found: std.ArrayList(rule.Diagnostic) = .empty;
    errdefer {
        for (found.items) |*item| item.deinit(testing.allocator);
        found.deinit(testing.allocator);
    }
    try check(testing.allocator, source, options, &found);
    return found;
}

fn deinit(found: *std.ArrayList(rule.Diagnostic)) void {
    for (found.items) |*item| item.deinit(testing.allocator);
    found.deinit(testing.allocator);
}

test "max-file-lines: a file at the ceiling is allowed" {
    var found = try findings("const a = 1;\nconst b = 2;\nconst c = 3;\n", .{ .max_file_lines = 3 });
    defer deinit(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "max-file-lines: one line over is reported at the line that tipped it" {
    var found = try findings("const a = 1;\nconst b = 2;\nconst c = 3;\nconst d = 4;\n", .{ .max_file_lines = 3 });
    defer deinit(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 4), found.items[0].line);
    try testing.expectEqualStrings("File has 4 code lines; max is 3", found.items[0].message);
}

test "max-file-lines: blank lines and comment lines do not count" {
    const source =
        "\n" ++
        "// one\n" ++
        "// two\n" ++
        "\n" ++
        "const a = 1;\n" ++
        "\n" ++
        "const b = 2;\n" ++
        "\n";
    var found = try findings(source, .{ .max_file_lines = 2 });
    defer deinit(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "max-file-lines: a block comment spanning lines is not code" {
    const source = "/* one\n two\n three\n*/\nconst a = 1;\n";
    var found = try findings(source, .{ .max_file_lines = 1 });
    defer deinit(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "max-file-lines: a trailing comment after code still counts as code" {
    const source = "const a = 1; // one\nconst b = 2; // two\n";
    var found = try findings(source, .{ .max_file_lines = 1 });
    defer deinit(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 2), found.items[0].line);
}

test "max-file-lines: a multi-line string counts every line it spans" {
    const fence = [2]u8{ 92, 92 };
    const source = "const s =\n    " ++ fence ++ "one\n    " ++ fence ++ "two\n;\n";
    var found = try findings(source, .{ .max_file_lines = 3 });
    defer deinit(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 4), found.items[0].line);
}

test "max-file-lines: a long file produces one finding, not one per line" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..50) |_| try source.appendSlice(testing.allocator, "const x = 1;\n");

    var found = try findings(source.items, .{ .max_file_lines = 10 });
    defer deinit(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 11), found.items[0].line);
    try testing.expectEqualStrings("File has 50 code lines; max is 10", found.items[0].message);
}

test "max-file-lines: the ceiling defaults to two thousand" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..2_001) |_| try source.appendSlice(testing.allocator, "const x = 1;\n");

    var found = try findings(source.items, .{});
    defer deinit(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 2_001), found.items[0].line);
}

test "max-file-lines: a file whose length is padded by comments is allowed" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..2_000) |_| try source.appendSlice(testing.allocator, "// filler\n");
    for (0..2_000) |_| try source.appendSlice(testing.allocator, "const x = 1;\n");

    var found = try findings(source.items, .{});
    defer deinit(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "max-file-lines: a diagnostic names its rule" {
    var found = try findings("const a = 1;\nconst b = 2;\n", .{ .max_file_lines = 1 });
    defer deinit(&found);
    try testing.expectEqualStrings("zginlint/max-file-lines", found.items[0].rule_id);
    try testing.expectEqual(@as(u32, 1), found.items[0].column);
}

test "max-file-lines: the fingerprint carries the ceiling" {
    const text = try fingerprint(testing.allocator, .{ .max_file_lines = 1500 });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("max=1500", text);
}
