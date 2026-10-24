//! `zginlint/no-std-log-warn`: the bare warn call through `std.log` is banned
//! in favour of the project's Logger, because the test runner owns that stream
//! and relays it — see README.md.

const std = @import("std");
const rule = @import("../rule.zig");

pub const id = "zginlint/no-std-log-warn";

/// The banned token, concatenated so this source carries no literal copy of
/// what it rejects (the scan is over raw bytes, including this file).
const banned = "std.log" ++ "." ++ "warn";

/// The message, built the same way for the same reason.
const message_fmt = "`std.log{s}warn` writes to the test runner's stderr, so a PASSING test that" ++
    " reaches it makes `zig build test` print a `run test w` block with no test name." ++
    " Warn through the global Logger instead:" ++
    " `if (loggermod.getGlobal()) |logger| logger.warnFmt(…)` — silent in a test, warns in a server.";

pub const declaration = rule.Rule{
    .id = id,
    .fingerprint = fingerprint,
    .check = check,
};

pub fn fingerprint(allocator: std.mem.Allocator, options: rule.Options) ![]u8 {
    _ = options;
    return allocator.dupe(u8, rule.no_options);
}

/// Append one diagnostic per site, at the `std` that starts it.
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
        // `std.log.warnFoo` / `std.log.warned` are not the call.
        if (search_from < source.len and isWordByte(source[search_from])) continue;

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

test "no-std-log-warn: the site is reported at the std it starts" {
    const source = try sourceWithSite(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);

    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqual(@as(u32, 1), found.items[0].line);
    try testing.expectEqual(@as(u32, 11), found.items[0].column);
    try testing.expectEqualStrings(id, found.items[0].rule_id);
}

test "no-std-log-warn: the diagnostic names the call to use instead" {
    const source = try sourceWithSite(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);

    try testing.expect(std.mem.indexOf(u8, found.items[0].message, "warnFmt") != null);
    try testing.expect(std.mem.indexOf(u8, found.items[0].message, "zig build test") != null);
}

test "no-std-log-warn: info and err are not this ban" {
    const source = "const a = std.log.info(\"x\", .{});\nconst b = std.log.err(\"y\", .{});\n";
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-std-log-warn: a longer identifier after the token is not the call" {
    const source = try std.fmt.allocPrint(testing.allocator, "const x = {s}ing;\n", .{banned});
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-std-log-warn: the Logger call is not reported" {
    const source = "if (loggermod.getGlobal()) |logger| logger.warnFmt(\"x {s}\", .{\"y\"});\n";
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-std-log-warn: a commented-out site is reported" {
    const source = try std.fmt.allocPrint(testing.allocator, "// old: {s}(\"boom\", .{{}});\n", .{banned});
    defer testing.allocator.free(source);
    var found = try checkOwned(source);
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
}

test "no-std-log-warn: two sites are two findings, in source order" {
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
