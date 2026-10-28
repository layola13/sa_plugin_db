//! In-process epoch runtime for the qmod layer (VM concurrency,
//! Model A: snapshot readers + single-writer epoch commit; see
//! docs/vm_concurrency_epoch.md).
//!
//! The storage layer already versions every table by epoch and
//! publishes commits through the table manifest. This module gives
//! qmod executions an in-process protocol on top of that:
//!
//! - A reader *pins* the latest committed epoch at exec start. The
//!   pin carries the pinned epoch's meta bytes, so every segment
//!   load in that exec resolves against one named, consistent
//!   epoch, and the registry can account for which epochs are in
//!   use.
//! - A writer's successful commit *swaps* the registry's current
//!   pin to the new epoch (noteCommitted), retiring the previous
//!   one. Readers already pinned finish on their epoch; readers
//!   that pin afterwards start on the new one.
//! - A retired pin is freed exactly when its last holder releases
//!   it — never while a reader still holds it (the epoch GC rule).
//!
//! The manifest on disk stays the cross-process source of truth:
//! every pin validates the candidate meta (epoch + SHA-256 of the
//! meta bytes) against a fresh read of the active meta, so external
//! commits and restores are adopted on the next pin, in either
//! direction (advance or restore regression). The registry never
//! invents an epoch.
//!
//! This module is deliberately dependency-free (no table.zig
//! import): callers supply the meta bytes and epoch they resolved
//! through the storage layer. All registry-owned memory uses the
//! page allocator, following the wal_dir_synced precedent in
//! table.zig, so pin lifetimes never couple to a per-exec
//! allocator. No network, file, or SQL surface exists here.

const std = @import("std");

pub const EpochPin = struct {
    epoch: u64,
    meta_source: []const u8,
    meta_hash: [32]u8,
    /// Guarded by the owning TableState.mutex. Counts every holder,
    /// including the registry itself while this pin is `current`.
    refs: u32 = 1,
    /// Guarded by the owning TableState.mutex. Set when the pin is
    /// superseded; the pin is freed when refs drain to zero.
    retired: bool = false,
    /// Opaque attachment owned by the qmod layer (the materialized
    /// snapshot cache in db_stub.zig). epoch_runtime never inspects
    /// it; it only hands it to `pin_free_hook` when the pin is
    /// freed. Set by a pin holder while it holds a reference, so
    /// the pin cannot be freed concurrently with the attach.
    attachment: ?*anyopaque = null,
};

/// Optional hook invoked from `freePin` just before the pin's own
/// memory is released, so the qmod layer can free whatever it
/// attached (see `EpochPin.attachment`). Set once by db_stub before
/// its first pin; null in this module's own tests, where nothing is
/// ever attached.
pub var pin_free_hook: ?*const fn (pin: *EpochPin) void = null;

const TableState = struct {
    mutex: std.atomic.Mutex = .unlocked,
    current: ?*EpochPin = null,
    /// Live caller-held pins per epoch (excludes the registry's own
    /// hold on `current`). Backs oldestLiveEpoch / livePinCount.
    live_by_epoch: std.AutoHashMapUnmanaged(u64, u32) = .{},
};

var registry_mutex: std.atomic.Mutex = .unlocked;
var registry: std.StringHashMapUnmanaged(*TableState) = .{};
const registry_allocator = std.heap.page_allocator;

fn stateForTable(table_name: []const u8) error{OutOfMemory}!*TableState {
    while (!registry_mutex.tryLock()) std.atomic.spinLoopHint();
    defer registry_mutex.unlock();
    if (registry.get(table_name)) |state| return state;
    const state = try registry_allocator.create(TableState);
    state.* = .{};
    const key = try registry_allocator.dupe(u8, table_name);
    registry.put(registry_allocator, key, state) catch |err| {
        registry_allocator.free(key);
        registry_allocator.destroy(state);
        return err;
    };
    return state;
}

/// Drop the registry's hold on `state.current` (which must be
/// `pin`), retiring it. Caller must hold state.mutex. The pin is
/// freed here iff no reader holds it anymore.
fn retireCurrentLocked(state: *TableState, pin: *EpochPin) void {
    std.debug.assert(state.current == pin);
    state.current = null;
    pin.retired = true;
    pin.refs -= 1; // the registry's own hold
    if (pin.refs == 0) freePin(pin);
}

fn freePin(pin: *EpochPin) void {
    if (pin.attachment != null) {
        if (pin_free_hook) |hook| hook(pin);
    }
    registry_allocator.free(pin.meta_source);
    registry_allocator.destroy(pin);
}

/// Pin the latest committed epoch of `table_name`.
///
/// `active_meta_source` must be the meta bytes just resolved
/// through the table manifest by the caller, and `active_epoch` /
/// `active_meta_hash` its epoch and SHA-256. If the registry's
/// current pin matches both, it is shared; otherwise a new pin is
/// adopted (taking its own copy of the meta bytes) and the old
/// current is retired. The returned pin stays valid until
/// `release` — its meta bytes are immutable and owned by the pin.
pub fn pinLatest(
    table_name: []const u8,
    active_meta_source: []const u8,
    active_epoch: u64,
    active_meta_hash: [32]u8,
) error{OutOfMemory}!*EpochPin {
    const state = try stateForTable(table_name);
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    defer state.mutex.unlock();

    if (state.current) |current| {
        if (current.epoch == active_epoch and std.mem.eql(u8, &current.meta_hash, &active_meta_hash)) {
            current.refs += 1;
            try noteLiveLocked(state, active_epoch);
            return current;
        }
        retireCurrentLocked(state, current);
    }

    const pin = try registry_allocator.create(EpochPin);
    errdefer registry_allocator.destroy(pin);
    const meta_copy = try registry_allocator.dupe(u8, active_meta_source);
    pin.* = .{
        .epoch = active_epoch,
        .meta_source = meta_copy,
        .meta_hash = active_meta_hash,
        .refs = 2, // registry's hold + the caller's hold
        .retired = false,
    };
    state.current = pin;
    try noteLiveLocked(state, active_epoch);
    return pin;
}

fn noteLiveLocked(state: *TableState, epoch: u64) error{OutOfMemory}!void {
    const entry = try state.live_by_epoch.getOrPut(registry_allocator, epoch);
    if (!entry.found_existing) entry.value_ptr.* = 0;
    entry.value_ptr.* += 1;
}

/// Release one hold on a pin obtained from `pinLatest`. Frees the
/// pin iff it was retired and this was the last hold.
pub fn release(table_name: []const u8, pin: *EpochPin) void {
    const state = stateForTable(table_name) catch return;
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    defer state.mutex.unlock();

    if (state.live_by_epoch.getPtr(pin.epoch)) |count| {
        count.* -= 1;
        if (count.* == 0) _ = state.live_by_epoch.remove(pin.epoch);
    }
    pin.refs -= 1;
    if (pin.refs == 0) {
        std.debug.assert(pin.retired);
        freePin(pin);
    }
}

/// Record that `table_name` committed `new_epoch` in this process.
/// The registry's current pin is retired (the swap); the next
/// `pinLatest` adopts the new epoch from the manifest. Called at
/// the success tail of the qmod commit path only — a commit that
/// staged no changes does not bump the epoch and must not call
/// this.
pub fn noteCommitted(table_name: []const u8, new_epoch: u64) void {
    const state = stateForTable(table_name) catch return;
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    defer state.mutex.unlock();
    if (state.current) |current| {
        if (current.epoch != new_epoch) retireCurrentLocked(state, current);
    }
}

/// Number of caller-held pins for a table (test/diagnostic
/// observability; the registry's own hold on current is excluded).
pub fn livePinCount(table_name: []const u8) usize {
    const state = stateForTable(table_name) catch return 0;
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    defer state.mutex.unlock();
    var total: usize = 0;
    var it = state.live_by_epoch.valueIterator();
    while (it.next()) |count| total += count.*;
    return total;
}

/// The oldest epoch with at least one live caller-held pin, or
/// null. This is the floor a future on-disk reaper must respect
/// (docs/vm_concurrency_epoch.md §3.3).
pub fn oldestLiveEpoch(table_name: []const u8) ?u64 {
    const state = stateForTable(table_name) catch return null;
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    defer state.mutex.unlock();
    var oldest: ?u64 = null;
    var it = state.live_by_epoch.keyIterator();
    while (it.next()) |epoch| {
        if (oldest == null or epoch.* < oldest.?) oldest = epoch.*;
    }
    return oldest;
}

/// Epoch of the registry's current pin for a table, or null.
pub fn currentEpoch(table_name: []const u8) ?u64 {
    const state = stateForTable(table_name) catch return null;
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    defer state.mutex.unlock();
    const current = state.current orelse return null;
    return current.epoch;
}

// ------------------------------------------------------------------
// Tests: pure registry behavior with synthetic meta bytes. Tables on
// disk are exercised by the db_stub concurrency tests; here the
// pin/retire/drain mechanics are pinned down without I/O.
// ------------------------------------------------------------------

test "epoch runtime shares a matching pin and counts live holds" {
    const table = "epoch_rt_share";
    const meta = "{\"epoch\": 7}";
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(meta, &hash, .{});

    const first = try pinLatest(table, meta, 7, hash);
    const second = try pinLatest(table, meta, 7, hash);
    try std.testing.expect(first == second);
    try std.testing.expectEqual(@as(usize, 2), livePinCount(table));
    try std.testing.expectEqual(@as(?u64, 7), currentEpoch(table));
    try std.testing.expectEqual(@as(?u64, 7), oldestLiveEpoch(table));

    release(table, first);
    try std.testing.expectEqual(@as(usize, 1), livePinCount(table));
    release(table, second);
    try std.testing.expectEqual(@as(usize, 0), livePinCount(table));
    // The registry still holds `current`; nothing was freed early.
    try std.testing.expectEqual(@as(?u64, 7), currentEpoch(table));
}

test "epoch runtime retires on commit and frees only after drain" {
    const table = "epoch_rt_retire";
    const meta7 = "{\"epoch\": 7}";
    const meta8 = "{\"epoch\": 8}";
    var hash7: [32]u8 = undefined;
    var hash8: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(meta7, &hash7, .{});
    std.crypto.hash.sha2.Sha256.hash(meta8, &hash8, .{});

    const old_pin = try pinLatest(table, meta7, 7, hash7);
    noteCommitted(table, 8);
    // The old pin is retired but still held by this test: its meta
    // bytes must remain readable (a live reader's epoch is never
    // reclaimed underneath it).
    try std.testing.expectEqual(@as(u64, 7), old_pin.epoch);
    try std.testing.expectEqualStrings(meta7, old_pin.meta_source);
    try std.testing.expectEqual(@as(?u64, null), currentEpoch(table));
    try std.testing.expectEqual(@as(?u64, 7), oldestLiveEpoch(table));

    const new_pin = try pinLatest(table, meta8, 8, hash8);
    try std.testing.expect(new_pin != old_pin);
    try std.testing.expectEqual(@as(?u64, 8), currentEpoch(table));
    try std.testing.expectEqual(@as(?u64, 7), oldestLiveEpoch(table));

    release(table, old_pin); // drains the retired pin -> freed here
    try std.testing.expectEqual(@as(?u64, 8), oldestLiveEpoch(table));
    release(table, new_pin);
    try std.testing.expectEqual(@as(usize, 0), livePinCount(table));
}

test "epoch runtime adopts a restore regression by hash, not just epoch" {
    const table = "epoch_rt_restore";
    const meta_a = "{\"epoch\": 3, \"shape\": \"a\"}";
    const meta_b = "{\"epoch\": 3, \"shape\": \"b\"}";
    var hash_a: [32]u8 = undefined;
    var hash_b: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(meta_a, &hash_a, .{});
    std.crypto.hash.sha2.Sha256.hash(meta_b, &hash_b, .{});

    const pin_a = try pinLatest(table, meta_a, 3, hash_a);
    // Same epoch number, different meta bytes (a restore that
    // republishes epoch 3 with different content): must adopt, not
    // share, because the hash differs.
    const pin_b = try pinLatest(table, meta_b, 3, hash_b);
    try std.testing.expect(pin_a != pin_b);
    try std.testing.expectEqualStrings(meta_b, pin_b.meta_source);
    release(table, pin_a);
    release(table, pin_b);
}
