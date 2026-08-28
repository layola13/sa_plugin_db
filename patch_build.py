p = "build.zig"
s = open(p, encoding="utf-8").read()
anchor = '''    link.addArg("-o");
    const out = link.addOutputFileArg(out_name);
    link.step.dependOn(&build_obj.step);
    bench_step.dependOn(&link.step);
    return out;
}'''
addition = '''    link.addArg("-o");
    const out = link.addOutputFileArg(out_name);
    link.step.dependOn(&build_obj.step);
    bench_step.dependOn(&link.step);
    try stageSqliteRuntimeNextToOut(b, bench_step, link, out, sqlite_lib);
    return out;
}

fn stageSqliteRuntimeNextToOut(
    b: *std.Build,
    bench_step: *std.Build.Step,
    link: *std.Build.Step.Run,
    out: std.Build.LazyPath,
    sqlite_lib: []const u8,
) void {
    const copy_sqlite = b.addSystemCommand(&.{ "cp", "-f", sqlite_lib, out });
    copy_sqlite.step.dependOn(&link.step);
    bench_step.dependOn(&copy_sqlite.step);
    if (b.graph.host.result.os.tag == .windows) {
        const enlarge_stack = b.addSystemCommand(&.{ "editbin", "/STACK:16777216", out });
        enlarge_stack.step.dependOn(&copy_sqlite.step);
        bench_step.dependOn(&enlarge_stack.step);
    }
}'''
assert s.count(anchor) == 1, s.count(anchor)
s = s.replace(anchor, addition)
open(p, "w", encoding="utf-8").write(s)
print("patched build.zig")
