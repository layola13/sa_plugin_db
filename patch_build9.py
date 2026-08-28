import io
path = "build.zig"
with io.open(path, "r", encoding="utf-8") as f:
    src = f.read()

old = '''fn addSaBenchStep(
    b: *std.Build,
    bench_step: *std.Build.Step,
    sa_bin: []const u8,
    plugins_home: []const u8,
    plugins_home_lock: []const u8,
    lock_wait_seconds_arg: []const u8,
    install_step: *std.Build.Step,
    source_rel: []const u8,
    out_name: []const u8,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, plugins_home_lock, sa_bin, "build-exe", source_rel });
    cmd.setEnvironmentVariable("SA_PLUGINS_HOME", plugins_home);
    cmd.setEnvironmentVariable("SA_PLUGIN_DEV", "1");
    cmd.addFileInput(b.path(source_rel));
    cmd.addFileInput(b.path("benchmark_test/db.sai"));
    cmd.addFileInput(b.path("benchmark_test/db.sal"));
    cmd.addArg("-o");
    const out = cmd.addOutputFileArg(out_name);
    cmd.addArg("--no-incremental");
    cmd.step.dependOn(install_step);
    bench_step.dependOn(&cmd.step);
    stageDbRuntimeNextToOut(b, bench_step, cmd, out, plugins_home);
    if (b.graph.host.result.os.tag == .windows) {
        const enlarge_stack = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; out='$1'; eb='${EDITBIN:-editbin}'; if command -v '$eb' >/dev/null 2>&1; then '$eb' /STACK:16777216 '$out'; fi" });
        enlarge_stack.addFileArg(out);
        enlarge_stack.step.dependOn(&cmd.step);
        bench_step.dependOn(&enlarge_stack.step);
    }
    return out;
}

fn stageDbRuntimeNextToOut(
    b: *std.Build,
    bench_step: *std.Build.Step,
    build_cmd: *std.Build.Step.Run,
    out: std.Build.LazyPath,
    plugins_home: []const u8,
) void {
    const db_dll = b.pathJoin(&.{ plugins_home, "installed", "db", "current", "db.dll" });
    const copy_db = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipifail; cp -f '$1' '$2'" });
    copy_db.addFileInput(.{ .cwd_relative = db_dll });
    copy_db.addFileArg(.{ .cwd_relative = db_dll });
    copy_db.addFileArg(out);
    copy_db.step.dependOn(&build_cmd.step);
    bench_step.dependOn(&copy_db.step);
}
'''

new = '''fn addSaBenchStep(
    b: *std.Build,
    bench_step: *std.Build.Step,
    sa_bin: []const u8,
    plugins_home: []const u8,
    plugins_home_lock: []const u8,
    lock_wait_seconds_arg: []const u8,
    install_step: *std.Build.Step,
    source_rel: []const u8,
    out_name: []const u8,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, plugins_home_lock, sa_bin, "build-exe", source_rel });
    cmd.setEnvironmentVariable("SA_PLUGINS_HOME", plugins_home);
    cmd.setEnvironmentVariable("SA_PLUGIN_DEV", "1");
    cmd.addFileInput(b.path(source_rel));
    cmd.addFileInput(b.path("benchmark_test/db.sai"));
    cmd.addFileInput(b.path("benchmark_test/db.sal"));
    cmd.addArg("-o");
    const raw_out = cmd.addOutputFileArg(out_name);
    cmd.addArg("--no-incremental");
    cmd.step.dependOn(install_step);
    bench_step.dependOn(&cmd.step);

    // Finalize the executable: stage db.dll next to it and enlarge the PE
    // stack on Windows. The returned path is the output of this finalize
    // step so downstream runs depend on the finalized binary, not the raw
    // build-exe output (which has a 1 MB stack and crashes the deep
    // recursion benchmarks with 0xC00000FD stack overflow).
    const finalize = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; src='$1'; out='$2'; dbdll='$3'; dst_dir=$(dirname '$out'); cp -f '$src' '$out'; if [ -n '$dbdll' ] && [ -f '$dbdll' ]; then cp -f '$dbdll' '$dst_dir/db.dll'; fi; eb='${EDITBIN:-editbin}'; if command -v '$eb' >/dev/null 2>&1; then '$eb' /STACK:16777216 '$out'; fi" });
    finalize.addFileArg(raw_out);
    const finalized_out = finalize.addOutputFileArg(out_name);
    finalize.addArg("PLACEHOLDER");
    const db_dll = b.pathJoin(&.{ plugins_home, "installed", "db", "current", "db.dll" });
    finalize.addFileArg(.{ .cwd_relative = db_dll });
    finalize.step.dependOn(&cmd.step);
    bench_step.dependOn(&finalize.step);
    stageDbDllNextToOut(b, bench_step, finalize, finalized_out, plugins_home);
    return finalized_out;
}

// Stage db.dll next to the finalized executable. The db bench loads db.dll
// via $ORIGIN, so it must sit beside the .out at run time.
fn stageDbDllNextToOut(
    b: *std.Build,
    bench_step: *std.Build.Step,
    finalize: *std.Build.Step.Run,
    out: std.Build.LazyPath,
    plugins_home: []const u8,
) void {
    const db_dll = b.pathJoin(&.{ plugins_home, "installed", "db", "current", "db.dll" });
    const copy_db = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f '$1' '$2'" });
    copy_db.addFileArg(.{ .cwd_relative = db_dll });
    copy_db.addFileArg(out);
    copy_db.step.dependOn(&finalize.step);
    bench_step.dependOn(&copy_db.step);
}
'''

assert src.count(old) == 1, "old block not found %d" % src.count(old)
src = src.replace(old, new)
with io.open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("patched")
