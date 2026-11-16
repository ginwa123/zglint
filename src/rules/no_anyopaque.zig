//! `zginlint/no-anyopaque`: the `anyopaque` token is banned inside the paths
//! named by `--no-anyopaque-paths`, each of which an allow entry can exempt.
//! An empty path list turns the rule off, so a tree passing no flag is unaffected.

const std = @import("std");
const rule = @import("../rule.zig");

pub const id = "zginlint/no-anyopaque";

/// The banned token, concatenated so this source carries no literal copy of
/// what it rejects (the scan is over raw bytes, including this file).
const banned = "any" ++ "opaque";

/// The message, built the same way for the same reason.
const message_fmt = "`{s}` is banned in this path: an erased pointer gives up the type" ++
    " this layer exists to keep. Keep the pointer typed, or route the one audited" ++
    " erasure through the allow-listed file.";

pub const declaration = rule.Rule{
    .id = id,
    .fingerprint = fingerprint,
    .check = check,
};

pub fn fingerprint(allocator: std.mem.Allocator, options: rule.Options) ![]u8 {
    if (options.no_anyopaque_paths.len == 0 and options.no_anyopaque_allow.len == 0) {
        return allocator.dupe(u8, rule.no_options);
    }
    const paths = try std.mem.join(allocator, ",", options.no_anyopaque_paths);
    defer allocator.free(paths);
    if (options.no_anyopaque_allow.len == 0) {
        return std.fmt.allocPrint(allocator, "paths={s}", .{paths});
    }
    const allow = try std.mem.join(allocator, ",", options.no_anyopaque_allow);
    defer allocator.free(allow);
    return std.fmt.allocPrint(allocator, "paths={s};allow={s}", .{ paths, allow });
}

/// Append one diagnostic per occurrence, unless this path is out of scope.
pub fn check(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    options: rule.Options,
    out: *std.ArrayList(rule.Diagnostic),
) anyerror!void {
    if (options.no_anyopaque_paths.len == 0) return;
    const normalised = try normalisedPath(allocator, path);
    defer allocator.free(normalised);
    if (!anyMatches(normalised, options.no_anyopaque_paths)) return;
    if (anyMatches(normalised, options.no_anyopaque_allow)) return;

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, banned)) |found| {
        search_from = found + banned.len;
        // A word boundary on both sides: `?*anyopaqueCtx`, `anyopaqueness` and
        // `my_anyopaque` are longer identifiers, not the token.
        if (found > 0 and isWordByte(source[found - 1])) continue;
        if (search_from < source.len and isWordByte(source[search_from])) continue;

        const position = positionOf(source, found);
        const message = try std.fmt.allocPrint(allocator, message_fmt, .{banned});
        errdefer allocator.free(message);
        try out.append(allocator, .{
            .rule_id = id,
            .line = position.line,
            .column = position.column,
            .message = message,
        });
    }
}

/// The path with every `\` read as `/`, so a Windows walk matches the entries
/// a POSIX one was written with.
fn normalisedPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const copy = try allocator.dupe(u8, path);
    for (copy) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return copy;
}

fn anyMatches(path: []const u8, entries: []const []const u8) bool {
    for (entries) |entry| {
        if (matches(path, entry)) return true;
    }
    return false;
}

/// An entry matches on a directory boundary only — the path is the entry, or
/// carries it whole between slashes, so an absolute path still matches a
/// relative entry and a bare file name is never enough.
fn matches(path: []const u8, entry: []const u8) bool {
    if (entry.len == 0 or entry.len > path.len) return false;
    if (std.mem.eql(u8, path, entry)) return true;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, path, from, entry)) |found| {
        from = found + 1;
        const end = found + entry.len;
        const after_slash = found == 0 or path[found - 1] == '/';
        const before_slash = end == path.len or path[end] == '/';
        if (after_slash and before_slash) return true;
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

/// The `\b` the ripgrep lint has around the word, without a regex engine.
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

const testing = std.testing;

/// A source with two occurrences, built so this test file carries no literal
/// copy of the token (which would itself be a finding).
fn sourceWithPair(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "pub const Ctx = ?*{s};\npub const On = *const fn (?*{s}) void;\n",
        .{ banned, banned },
    );
}

fn inCore() rule.Options {
    return .{ .no_anyopaque_paths = &.{"src/core"} };
}

fn checkOwned(path: []const u8, source: []const u8, options: rule.Options) !std.ArrayList(rule.Diagnostic) {
    var found: std.ArrayList(rule.Diagnostic) = .empty;
    errdefer {
        for (found.items) |*item| item.deinit(testing.allocator);
        found.deinit(testing.allocator);
    }
    try check(testing.allocator, path, source, options, &found);
    return found;
}

fn deinitFound(found: *std.ArrayList(rule.Diagnostic)) void {
    for (found.items) |*item| item.deinit(testing.allocator);
    found.deinit(testing.allocator);
}

test "no-anyopaque: a banned path reports the token at its line and column" {
    const source = try sourceWithPair(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned("src/core/props.zig", source, inCore());
    defer deinitFound(&found);

    try testing.expectEqual(@as(usize, 2), found.items.len);
    try testing.expectEqual(@as(u32, 1), found.items[0].line);
    try testing.expectEqual(@as(u32, 19), found.items[0].column);
    try testing.expectEqual(@as(u32, 2), found.items[1].line);
    try testing.expectEqual(@as(u32, 29), found.items[1].column);
    try testing.expectEqualStrings(id, found.items[0].rule_id);
}

test "no-anyopaque: a path outside the ban is silent" {
    const source = try sourceWithPair(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned("src/app/props.zig", source, inCore());
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-anyopaque: a longer identifier around the token is silent" {
    const source = try std.fmt.allocPrint(
        testing.allocator,
        "pub const A = {s}Thing;\npub const B = my_{s};\npub const C = x{s};\n",
        .{ banned, banned, banned },
    );
    defer testing.allocator.free(source);
    var found = try checkOwned("src/core/props.zig", source, inCore());
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-anyopaque: the token is reported in a comment too, in source order" {
    const source = try std.fmt.allocPrint(
        testing.allocator,
        "// the old code held a ?*{s} here\npub const On = *const fn (?*{s}) void;\n",
        .{ banned, banned },
    );
    defer testing.allocator.free(source);
    var found = try checkOwned("src/core/props.zig", source, inCore());
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 2), found.items.len);
    try testing.expectEqual(@as(u32, 1), found.items[0].line);
    try testing.expectEqual(@as(u32, 2), found.items[1].line);
}

test "no-anyopaque: an allow-listed file is silent" {
    const source = try sourceWithPair(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned("src/core/erased.zig", source, .{
        .no_anyopaque_paths = &.{"src/core"},
        .no_anyopaque_allow = &.{"src/core/erased.zig"},
    });
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-anyopaque: an allow entry matches on a boundary, not inside a name" {
    const source = try sourceWithPair(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned("src/core/unerased.zig", source, .{
        .no_anyopaque_paths = &.{"src/core"},
        .no_anyopaque_allow = &.{"erased.zig"},
    });
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 2), found.items.len);
}

test "no-anyopaque: an absolute path matches a relative ban entry" {
    const source = try sourceWithPair(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned("/Users/x/proj/src/core/props.zig", source, inCore());
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 2), found.items.len);
}

test "no-anyopaque: a backslash path matches a forward-slash entry" {
    const source = try sourceWithPair(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned("src\\core\\props.zig", source, inCore());
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 2), found.items.len);
}

test "no-anyopaque: an empty path list reports nothing at all" {
    const source = try sourceWithPair(testing.allocator);
    defer testing.allocator.free(source);
    var found = try checkOwned("src/core/props.zig", source, .{});
    defer deinitFound(&found);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "no-anyopaque: the fingerprint is the no-options marker when off" {
    const text = try fingerprint(testing.allocator, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(rule.no_options, text);
}

test "no-anyopaque: the fingerprint carries the paths and the allow list" {
    const combined = try fingerprint(testing.allocator, .{
        .no_anyopaque_paths = &.{ "src/core", "src/ui" },
        .no_anyopaque_allow = &.{"src/core/erased.zig"},
    });
    defer testing.allocator.free(combined);
    try testing.expectEqualStrings("paths=src/core,src/ui;allow=src/core/erased.zig", combined);

    const banned_only = try fingerprint(testing.allocator, inCore());
    defer testing.allocator.free(banned_only);
    try testing.expectEqualStrings("paths=src/core", banned_only);
}
