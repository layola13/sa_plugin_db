#!/usr/bin/env bash
set -euo pipefail

# Regression test for the production scoping of the 1GiB readFileAlloc
# forbid in tests/check_hot_io_guards.sh (DEF-DB-HOT-IO-GUARD-RED disposal
# form B, decision round R248). The forbid must keep firing on production
# code at full strength, and must stop firing on test blocks and on
# private helpers referenced exclusively from test code (the adjudicated
# false positive: walTestAppendEpochUnit in src/table.zig).
#
# Usage: check_hot_io_guards_scope_test.sh [table_path]
# The guard under test is the sibling check_hot_io_guards.sh. Fixtures are
# text-only: the guard is a text scan, so they exercise it directly. Every
# fixture lacks the guard's required production wiring, so a fixture run
# always ends in a "hot I/O guard failed:" verdict from some later rule;
# the cases assert only whether the 1GiB forbid itself fired.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard_path="$script_dir/check_hot_io_guards.sh"
table_path="${1:-src/table.zig}"
item1_msg="1GiB readFileAlloc hot-path read reintroduced"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
guard_out=""

run_guard() {
    guard_out="$(bash "$guard_path" "$1" 2>&1)" || true
}

expect_item1() {
    run_guard "$1"
    if [[ "$guard_out" != *"$item1_msg"* ]]; then
        echo "scope test failed: $2 must report the 1GiB forbid, got: $guard_out" >&2
        failures=$((failures + 1))
    fi
}

expect_no_item1() {
    run_guard "$1"
    if [[ "$guard_out" != *"hot I/O guard failed:"* ]]; then
        echo "scope test failed: $2 guard did not reach a rule verdict, got: $guard_out" >&2
        failures=$((failures + 1))
    fi
    if [[ "$guard_out" == *"$item1_msg"* ]]; then
        echo "scope test failed: $2 must not report the 1GiB forbid, got: $guard_out" >&2
        failures=$((failures + 1))
    fi
}

expect_no_item1_real() {
    # The real table may legitimately reach either verdict overall (the
    # epoch-sync require is a separate item); the guard must have run and
    # the 1GiB forbid must not have fired.
    run_guard "$1"
    if [[ "$guard_out" != *"hot I/O guard "* ]]; then
        echo "scope test failed: $2 guard did not run, got: $guard_out" >&2
        failures=$((failures + 1))
    fi
    if [[ "$guard_out" == *"$item1_msg"* ]]; then
        echo "scope test failed: $2 must not report the 1GiB forbid, got: $guard_out" >&2
        failures=$((failures + 1))
    fi
}

cat >"$work/prod_violation.zig" <<'EOF'
const std = @import("std");

pub fn loadWholeFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readFileAlloc(allocator, path, 1 << 30);
}
EOF

cat >"$work/test_only.zig" <<'EOF'
const std = @import("std");

fn helperRead(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readFileAlloc(allocator, path, 1 << 30);
}

test "helper reads" {
    const bytes = try helperRead(std.testing.allocator, "x");
    _ = bytes;
}

test "direct read" {
    const bytes = try readFileAlloc(std.testing.allocator, "y", 1 << 30);
    _ = bytes;
}
EOF

cat >"$work/chain.zig" <<'EOF'
const std = @import("std");

fn innerRead(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readFileAlloc(allocator, path, 1 << 30);
}

fn outerRead(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return innerRead(allocator, path);
}

test "chain reads" {
    _ = try outerRead(std.testing.allocator, "x");
}
EOF

cat >"$work/mixed.zig" <<'EOF'
const std = @import("std");

fn sharedRead(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readFileAlloc(allocator, path, 1 << 30);
}

pub fn loadShared(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return sharedRead(allocator, path);
}

test "shared reads" {
    _ = try sharedRead(std.testing.allocator, "x");
}
EOF

expect_item1 "$work/prod_violation.zig" "production violation"
expect_no_item1 "$work/test_only.zig" "test-only reads"
expect_no_item1 "$work/chain.zig" "test-only helper chain"
expect_item1 "$work/mixed.zig" "production-referenced helper"
expect_no_item1_real "$table_path" "real table"

if [[ "$failures" -ne 0 ]]; then
    echo "hot I/O guard scope test failed: $failures case(s)" >&2
    exit 1
fi

echo "hot I/O guard scope test passed: 1GiB forbid is production-scoped (test-only reads excluded, production reads still rejected)"
