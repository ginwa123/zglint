//! `zginlint/no-std-debug-print`: a bare print through `std.debug` is banned in
//! production code in favour of the project's Logger — see README.md.

const std = @import("std");
const rule = @import("../rule.zig");

pub const id = "zginlint/no-std-debug-print";

/// The banned token, concatenated so this source carries no literal copy of
/// what it rejects (the scan is over raw bytes, including this file).
const banned = "std.debug" ++ "." ++ "print";

/// The message, built the same way for the same reason.
const message_fmt = "`std.debug{s}print` writes straight to stderr: no level, no timestamp, not in the" ++
    " log file. Print through the project's Logger instead — `loggermod.debugPrint(…)` for a raw" ++
    " console line (silent in a test), or `logger.infoFmt/warnFmt/errFmt` for a real log line.";

pub const declaration = rule.Rule{
    .id = id,
    .fingerprint = fingerprint,
    .check = check,
};

pub fn fingerprint(allocator: std.mem.Allocator, options: rule.Options) ![]u8 {
    _ = options;
    return allocator.dupe(u8, rule.no_options);
}

/// Append one diagnostic per site, at the `std` that starts it. A site inside a
/// `test` block is exempt (a failing test's diagnostic must reach stderr), and
/// so is one inside `fn debugPrint` — that IS the raw print being sanctioned.
pub fn check(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: rule.Options,
    out: *std.ArrayList(rule.Diagnostic),
) anyerror!void {
    _ = options;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, banned)) |found| {
        search_from = found + banned.len;
        // `std.debug.printer` / `std.debug.printed` are not the call.
        if (search_from < source.len and isWordByte(source[search_from])) continue;
        if (insideTestBlock(source, found)) continue;
        if (insideRawPrintHelper(source, found)) continue;

        const position = positionOf(source, found);
        const message = try std.fmt.allocPrint(allocator, message_fmt, .{"."});
        errdefer allocator.free(message);
        try out.append(allocator, .{
            .rule_id = id,
            .line = position.line,
            .column = position.column,
            .message = message,
        });
    }
}

/// Is `index` inside a `test` block? The block is found the way a human reads
/// it: walk up to the nearest line that starts at column 0 — the `test` that
/// opens the block, or the `}` that closed the one above it.
fn insideTestBlock(source: []const u8, index: usize) bool {
    var line_start = index;
    while (line_start > 0) {
        line_start -= 1;
        const starts_line = line_start == 0 or source[line_start - 1] == '\n';
        if (!starts_line) continue;
        const rest = source[line_start..];
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trimEnd(u8, rest[0..line_end], "\r");
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        return std.mem.startsWith(u8, line, "test") and
            (line.len == 4 or !isWordByte(line[4]));
    }
    return false;
}

/// Is `index` inside the body of `fn debugPrint`? That function is the one
/// place the raw print is allowed to live: it is what every other site calls.
fn insideRawPrintHelper(source: []const u8, index: usize) bool {
    const raw_print_fn = "debugPrint";
    var cursor = index;
    while (cursor > 0) {
        const window = source[0..cursor];
        const fn_at = std.mem.lastIndexOf(u8, window, "fn ") orelse return false;
        var name_at = fn_at + "fn ".len;
        while (name_at < source.len and
            (source[name_at] == ' ' or source[name_at] == '\t' or source[name_at] == '\n')) name_at += 1;
        var name_end = name_at;
        while (name_end < source.len and isNameByte(source[name_end])) name_end += 1;
        if (name_end > name_at and std.mem.eql(u8, source[name_at..name_end], raw_print_fn)) return true;
        cursor = fn_at;
    }
    return false;
}

const Position = struct { line: u32, column: u32 };

fn positionOf(source: []const u8, index: usize) Position {
    var line: u32 = 1;
    var line_start: usize = 0;
    for (source[0..index], 0..) |byte, position| {
        if (byte != '\n') continue;
        line += 1;
        line_start = position + 1;
    }
    return .{ .line = line, .column = @intCast(index - line_start + 1) };
}

/// The `\b` the ripgrep lint has after the word, without a regex engine.
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

const testing = std.testing;

/// A source with one site, built so this test file carries no literal copy of
/// the token (which would itself be a finding).
fn sourceWithSite(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "const x = {s}(\"boom\", .{{}});\n", .{banned});
}

fn checkOwned(source: []const u8) !std.ArrayList(rule.Diagnostic) {
    var found: std.ArrayList(rule.Diagnostic) = .empty;
    errdefer {
        for (found.items) |*item| item.deinit(testing.allocator);
        found.deinit(testing.allocator);
    }
    try check(testing.allocator, source, .{}, &found);
    return found;
}

fn deinitFound(found: *std.ArrayList(rule.Diagnostic)) void {
    for (found.items) |*item| item.deinit(testing.allocator);
    found.deinit(testing.allocator);
}

test "no-std-debug-print: the production site is reported at the std it starts" {
    const source = try sourceWithSite(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);

    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 1), found.items[0].line);
    try testing.expectEqual(@as(u32, 11), found.items[0].column);
    try testing.expectEqualStrings(id, found.items[0].rule_id);
}

test "no-std-debug-print: the diagnostic names the call to use instead" {
    const source = try sourceWithSite(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);

    try testing.expect(std.mem.indexOf(u8, found.items[0].message, "debugPrint") != null);
    try testing.expect(std.mem.indexOf(u8, found.items[0].message, "Logger") != null);
}

test "no-std-debug-print: a site inside a test block is a diagnostic, not a finding" {
    const site = try sourceWithSite(testing.allocator);
    defer testing.allocator.free(site);
    const source = try std.fmt.allocPrint(testing.allocator,
        \\test "reports something" {{
        \\    {s}
        \\}}
    , .{std.mem.trimEnd(u8, site, "\n")});
    defer testing.allocator.free(source);

    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-std-debug-print: a site after a closed test block is reported again" {
    const site = try sourceWithSite(testing.allocator);
    defer testing.allocator.free(site);
    const source = try std.fmt.allocPrint(testing.allocator,
        \\test "reports something" {{
        \\    try g();
        \\}}
        \\{s}
    , .{std.mem.trimEnd(u8, site, "\n")});
    defer testing.allocator.free(source);

    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 4), found.items[0].line);
}

test "no-std-debug-print: the Logger's own raw-print helper is exempt" {
    const source = try std.fmt.allocPrint(testing.allocator,
        \\pub fn debugPrint(comptime fmt: []const u8, args: anytype) void {{
        \\    {s}(fmt, args);
        \\}}
    , .{banned});
    defer testing.allocator.free(source);

    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-std-debug-print: another function with the raw print is still reported" {
    const source = try std.fmt.allocPrint(testing.allocator,
        \\pub fn debugLog(comptime fmt: []const u8, args: anytype) void {{
        \\    {s}(fmt, args);
        \\}}
    , .{banned});
    defer testing.allocator.free(source);

    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
}

test "no-std-debug-print: the Logger call is not reported" {
    var found = try checkOwned("loggermod.debugPrint(\"x {s}\\n\", .{\"y\"});\n");
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-std-debug-print: a longer identifier after the token is not the call" {
    const source = try std.fmt.allocPrint(testing.allocator, "const x = {s}ln;\n", .{banned});
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-std-debug-print: a commented-out site is reported" {
    const source = try std.fmt.allocPrint(testing.allocator, "// old: {s}(\"boom\", .{{}});\n", .{banned});
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
}

test "no-std-debug-print: two production sites are two findings, in source order" {
    const first = try sourceWithSite(testing.allocator);
    defer testing.allocator.free(first);
    const second = try std.fmt.allocPrint(testing.allocator, "{s}{s}(\"again\", .{{}});\n", .{ first, banned });
    defer testing.allocator.free(second);

    var found = try checkOwned(second);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 2), found.items.len);
    try testing.expectEqual(@as(u32, 1), found.items[0].line);
    try testing.expectEqual(@as(u32, 2), found.items[1].line);
}
