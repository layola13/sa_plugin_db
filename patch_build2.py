p = "build.zig"
s = open(p, encoding="utf-8").read()
anchor = '''    cmd.addArg("--no-incremental");
    cmd.step.dependOn(install_step);
    bench_step.dependOn(&cmd.step);
    return out;
}'''
addition = '''    cmd.addArg("--no-incremental");
    cmd.step.dependOn(install_step);
    bench_step.dependOn(&cmd.step);
    try stageDbRuntimeNextToOut(b, bench_step, cmd, out, plugins_home);
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
    const copy_db = b.addSystemCommand(&.{ "cp", "-f", db_dll, out });
    copy_db.addFileInput(.{ .cwd_relative = db_dll });
    copy_db.step.dependOn(&build_cmd.step);
    bench_step.dependOn(&copy_db.step);
}'''
assert s.count(anchor) == 1, s.count(anchor)
s = s.replace(anchor, addition)
open(p, "w", encoding="utf-8").write(s)
print("patched db side")
