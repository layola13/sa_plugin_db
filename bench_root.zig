//! Compile root for the concurrency bench (scripts/bench/).
//! Lives at the repo root so the root module's path covers both
//! src/ and scripts/bench/ for path imports. Build with:
//!   zig build-exe --dep sio --dep plugin_api \
//!     -Mroot=bench_root.zig -O ReleaseFast \
//!     -Msio=<sci>/src/sa_io.zig -Mplugin_api=src/plugin_api.zig
const std = @import("std");
const bench = @import("scripts/bench/bench_main.zig");

pub fn main(init: std.process.Init) !void {
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    defer args_it.deinit();
    var argv: std.array_list.Managed([]const u8) = .init(std.heap.smp_allocator);
    defer argv.deinit();
    while (args_it.next()) |arg| try argv.append(arg);
    try bench.runBench(argv.items);
}
