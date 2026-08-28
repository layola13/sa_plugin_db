p = "build.zig"
s = open(p, encoding="utf-8").read()

old_db = '''fn stageDbRuntimeNextToOut(
    b: *std.Build,
    bench_step: *std.Build.Step,
    build_cmd: *std.Build.Step.Run,
    out: std.Build.LazyPath,
    plugins_home: []const u8,
) void {
    const db_dll = b.pathJoin(&.{ plugins_home, "installed", "db", "current", "db.dll" });
    const copy_db = b.addSystemCommand(&.{ "cp", "-f", db_dll, out });
    copy_db.addFileInput(.{ .cwd_relative = db_dll });
    copy_db.addFileArg(out);
    copy_db.step.dependOn(&build_cmd.step);
    bench_step.dependOn(&copy_db.step);
}'''
new_db = '''fn stageDbRuntimeNextToOut(
    b: *std.Build,
    bench_step: *std.Build.Step,
    build_cmd: *std.Build.Step.Run,
    out: std.Build.LazyPath,
    plugins_home: []const u8,
) void {
    const db_dll = b.pathJoin(&.{ plugins_home, "installed", "db", "current", "db.dll" });
    const copy_db = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f \"$1\" \"$2\"", db_dll, out });
    copy_db.addFileInput(.{ .cwd_relative = db_dll });
    copy_db.addFileArg(out);
    copy_db.step.dependOn(&build_cmd.step);
    bench_step.dependOn(&copy_db.step);
}'''
assert old_db in s
s = s.replace(old_db, new_db)

old_sql = '''fn stageSqliteRuntimeNextToOut(
    b: *std.Build,
    bench_step: *std.Build.Step,
    link: *std.Build.Step.Run,
    out: std.Build.LazyPath,
    sqlite_lib: []const u8,
) void {
    const copy_sqlite = b.addSystemCommand(&.{ "cp", "-f", sqlite_lib, out });
    copy_sqlite.addFileInput(.{ .cwd_relative = sqlite_lib });
    copy_sqlite.addFileArg(out);
    copy_sqlite.step.dependOn(&link.step);
    bench_step.dependOn(&copy_sqlite.step);
    if (b.graph.host.result.os.tag == .windows) {
        const enlarge_stack = b.addSystemCommand(&.{ "editbin", "/STACK:16777216", out });
        enlarge_stack.addFileArg(out);
        enlarge_stack.step.dependOn(&copy_sqlite.step);
        bench_step.dependOn(&enlarge_stack.step);
    }
}'''
new_sql = '''fn stageSqliteRuntimeNextToOut(
    b: *std.Build,
    bench_step: *std.Build.Step,
    link: *std.Build.Step.Run,
    out: std.Build.LazyPath,
    sqlite_lib: []const u8,
) void {
    const copy_sqlite = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f \"$1\" \"$2\"", sqlite_lib, out });
    copy_sqlite.addFileInput(.{ .cwd_relative = sqlite_lib });
    copy_sqlite.addFileArg(out);
    copy_sqlite.step.dependOn(&link.step);
    bench_step.dependOn(&copy_sqlite.step);
    if (b.graph.host.result.os.tag == .windows) {
        const enlarge_stack = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; out=\"$1\"; eb=\"${EDITBIN:-editbin}\"; if command -v \"$eb\" >/dev/null 2>&1; then \"$eb\" /STACK:16777216 \"$out\"; fi", out });
        enlarge_stack.addFileArg(out);
        enlarge_stack.step.dependOn(&copy_sqlite.step);
        bench_step.dependOn(&enlarge_stack.step);
    }
}'''
assert old_sql in s
s = s.replace(old_sql, new_sql)

open(p, "w", encoding="utf-8").write(s)
print("rewrote helpers with bash -c")
