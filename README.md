# zginlint

A linter for Zig source, in the shape of ESLint: a lexer, a set of rules
that read it, and a report. There is no baseline and no suppression — a
finding is a finding, and the only way to clear one is to fix it.

It is a **standalone** repository — std only, no dependencies at all — so it
compiles without an app's dependency stack. (The GitHub repository is
`ginwa123/zglint`; the tool it ships is `zginlint`, which is also the
package name and the prefix of every rule id.) It lived at
`pabrik/src/modules/zginlint/` until it was moved out; `pabrik` is its first
consumer, pinning it by URL + hash in `build.zig.zon`.

## Use it

```bash
zig build                                 # build zig-out/bin/zginlint
zig-out/bin/zginlint src                  # report every finding, exit 1 if any
zig-out/bin/zginlint --max-comment-lines 2 src
zig-out/bin/zginlint --no-anyopaque-paths src/core --no-anyopaque-allow src/core/erased.zig src
zig build test                            # the linter's own unit tests
zig build lint                            # the gate this repo's CI runs
```

`zginlint --help` prints the whole surface. Exit codes are part of the
contract: `0` clean, `1` findings, `2` a usage or I/O error — a path the
tool could not read never reads as "the tree is clean".

## Consume it

```zig
const zginlint = b.dependency("zginlint", .{ .target = target, .optimize = optimize });
const exe = zginlint.artifact("zginlint");   // the CLI, host-targeted
const lib = zginlint.module("zginlint");     // the library, for embedders
```

The CLI and its tests are built for the HOST, whatever `-Dtarget` says: a
consumer cross-compiles its own artifacts and still has to run this binary
over its tree. A consumer's build never runs this repo's `test` step, so
the unit tests belong to `zig build test` here and to the CI below.

## The rules

### `zginlint/max-comment-lines`

A comment block may not exceed **3 lines** (`--max-comment-lines N`).

- A **comment line** carries comment content and no code byte.
- A **comment block** is a run of consecutive comment lines. A blank line
  or a line with code on it ends the block.
- A block longer than the ceiling produces one finding, at the block's
  first line: `src/a.zig:12:1: error Comment block has 7 lines; max is 3
  (zginlint/max-comment-lines)`.
- `///` doc comments and `//!` container docs are comments like any other
  and get no exemption.
- A trailing comment after code (`const x = 1; // note`) is not a block and
  is never counted.
- Comment markers inside a string or char literal, and inside a multi-line
  string fenced with `\\`, are text, not comments.
- Block comments nest, and `/* ... */` counts by the lines it spans.

### `zginlint/no-catch-unreachable`

The banned error-handling pair — the same rule as
`pabrik`'s `scripts/lint-no-catch-unreachable.sh`, and the reason
`CODING_STANDARDS.md` §1 exists: it panics with no usable message in
Debug/ReleaseSafe and is **undefined behaviour** in ReleaseFast.

- The finding is reported at the `catch`, with the column that starts it.
- The scan is over **raw bytes**, exactly like the ripgrep lint it mirrors,
  so a commented-out site counts (§1 asks for that) and so does one inside
  a string literal. There is no token-level exemption to argue about.
- One or more whitespace bytes are allowed between the two words, newlines
  included, so a wrapped `catch` / `unreachable` pair is still caught.
- A word boundary is required after it, so `somethingUnreachable` is not a
  hit; `catch @panic("...")` is the sanctioned form and is not one either.
- It takes no options, and its fingerprint is `-`.

### `zginlint/no-std-log-warn`

A bare `warn` through `std.log` is banned; warn through the project's Logger
instead. `std.log` writes to the test runner's stderr by definition, and the
runner relays **any** stderr byte from a **passing** test as a block that has
the exact shape of a failure — same header, same `failed command:` tail, but
without the failing test's name or counts. A green suite then reads as a
broken one. Measured on `pabrik`: exit 0, 4987/4991 tests passed, five such
blocks, and the next agent spent its first turn hunting a failure that did not
exist.

- The finding is reported at the `std` that starts the call, with its column.
- `warn` only: `std.log.info`/`.debug` are already silent under the runner
  (`testing.log_level` is `.warn`), and `.err` fails the test rather than
  printing a passing block.
- A word boundary is required after `warn`, so `std.log.warning` is not a hit.
- The sanctioned form is the global Logger, which is silent in a test because
  no test installs one:
  `if (loggermod.getGlobal()) |logger| logger.warnFmt("…", .{…});`
- The scan is over **raw bytes**, so a commented-out site counts.
- It takes no options, and its fingerprint is `-`.

A tree that still carries the old call adopts this rule only after migrating
those sites; `pabrik` counts them at 153 across 58 files, so the rule lands
here first and its pin moves when that migration does.

### `zginlint/no-anyopaque`

The `anyopaque` token is banned **inside the paths you name**, and nowhere
else. A UI engine's `src/core` holds typed callbacks; an ad-hoc
`?*anyopaque` pair — a function pointer plus its context — erases the type
that layer exists to keep, and nothing downstream can put it back. The ban
is **narrow on purpose**: one audited erasure file is the design, not a
compromise, so the rule ships with an allow list instead of a verdict.

- `--no-anyopaque-paths src/core,src/render` bans the token in those paths
  and everything under them. **Unset means the rule is off**: with no path
  in scope there is nothing to report, so a tree that passes no flag lints
  exactly as it did before this rule existed.
- An entry matches on a directory boundary only — the path is the entry,
  sits under it, or carries it whole between slashes. A relative
  `src/core/props.zig` and an absolute `/Users/x/proj/src/core/props.zig`
  both match `src/core`; a bare file name never matches a directory, and
  `src/core` never matches `src/corex`.
- `--no-anyopaque-allow src/core/erased.zig` exempts a file from the ban,
  with the same matching rules. That is the point of the flag rather than a
  hole in the rule: erasure stays legal exactly where someone audited it,
  and the exemption lives in the build script where a reviewer sees it,
  instead of in a comment inside the source.
- One finding per occurrence, at the token's line and column:
  ``src/core/props.zig:12:24: error `anyopaque` is banned in this path: an
  erased pointer gives up the type this layer exists to keep. …
  (zginlint/no-anyopaque)``.
- A word boundary is required on both sides, so `anyopaqueCtx` and
  `my_anyopaque` are longer identifiers and are not hits. The scan is over
  **raw bytes**, so a commented-out site counts.
- The fingerprint is `-` while both lists are empty, and
  `paths=src/core;allow=src/core/erased.zig` once they are set.

This is the rule that made the rule API path-aware: `Rule.check` takes the
display path the walker reported, second, before the source. A path-blind
rule ignores it; this one cannot.

## No baseline, no suppression

The gate asks for **zero**. There is no pin file, no per-file ceiling, no
`--baseline` flag and no `zig build zginlint:pin` step — the ratchet that
let a rule ship on an unconverted tree was deleted once the tree was
converted, because a baseline allowlist is a rule nobody can tell is being
followed (CODING_STANDARDS.md §3 rule 5, applied to §4 itself).

`zginlint/max-comment-lines` carried 6,532 findings across 727 files when
it landed. All of them were converted — every over-long block re-wrapped to
at most three lines, cut at a sentence boundary — and the conversion was
verified to touch comment lines only: zero findings remain, `zig ast-check`
is clean on every file, and the sequence of code-bearing lines is
byte-identical to the pre-conversion tree.

A rule that needs an escape hatch does not have one here. If a block
genuinely cannot be said in three lines, the prose belongs in a doc, the
commit message or this README — not in a suppression comment.

## Layout

| file | what it owns |
|---|---|
| `src/comment_scan.zig` | the lexer: source bytes in, comment lines and blocks out |
| `src/rules/max_comment_lines.zig` | the comment-block ceiling |
| `src/rules/no_anyopaque.zig` | the path-scoped token ban |
| `src/rules/no_catch_unreachable.zig` | the banned error-handling pair |
| `src/rules/no_std_log_warn.zig` | the banned bare `warn` through `std.log` |
| `src/diagnostic.zig` | a finding and the message its rule wrote |
| `src/rule.zig` | what a rule is: id, options fingerprint, check |
| `src/options.zig` | the options every rule is read with |
| `src/zginlint.zig` | the engine: the rule list, `lintSource`, the tree walk, the ordering |
| `src/cli.zig` | argv parsing, the report, the exit codes |
| `src/main.zig` | the thin exe entry point |
| `src/test_root.zig` | the test root `zig build test` runs |
| `build.zig` | the exe, the `zginlint` module, `test` and `lint` |

Adding a rule: put it in `src/rules/`, give it a field in `options.zig` if it
needs one, add its declaration to `zginlint.rules`, and add its path to
`test_root.zig`.

## Where it runs

`.github/workflows/ci.yml` runs `zig build`, `zig build test` and
`zig build lint` on Linux, macOS and Windows — the three platforms
`pabrik`'s backend cells cover.

The consumer owns the gate on its own tree: `pabrik` runs the pinned CLI
over `src`, `tests`, `tools` and `build.zig` with `zig build zginlint:check`,
mirrored by its `.husky/pre-commit`. Both fail on any finding.
