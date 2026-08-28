p = "build.zig"
s = open(p, encoding="utf-8").read()

old_db = '''    const db_dll = b.pathJoin(&.{ plugins_home, "installed", "db", "current", "db.dll" });
    const copy_db = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f \x27$1\x27 \x27$2\x27", db_dll, out });
    copy_db.addFileInput(.{ .cwd_relative = db_dll });
    copy_db.addFileArg(out);
    copy_db.step.dependOn(&build_cmd.step);
    bench_step.dependOn(&copy_db.step);'''
new_db = '''    const db_dll = b.pathJoin(&.{ plugins_home, "installed", "db", "current", "db.dll" });
    const copy_db = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f \x27$1\x27 \x27$2\x27" });
    copy_db.addFileInput(.{ .cwd_relative = db_dll });
    copy_db.addFileArg(.{ .cwd_relative = db_dll });
    copy_db.addFileArg(out);
    copy_db.step.dependOn(&build_cmd.step);
    bench_step.dependOn(&copy_db.step);'''
assert old_db in s, "db"
s = s.replace(old_db, new_db)

old_sql = '''    const copy_sqlite = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f \x27$1\x27 \x27$2\x27", sqlite_lib, out });
    copy_sqlite.addFileInput(.{ .cwd_relative = sqlite_lib });
    copy_sqlite.addFileArg(out);
    copy_sqlite.step.dependOn(&link.step);
    bench_step.dependOn(&copy_sqlite.step);'''
new_sql = '''    const copy_sqlite = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f \x27$1\x27 \x27$2\x27" });
    copy_sqlite.addFileInput(.{ .cwd_relative = sqlite_lib });
    copy_sqlite.addFileArg(.{ .cwd_relative = sqlite_lib });
    copy_sqlite.addFileArg(out);
    copy_sqlite.step.dependOn(&link.step);
    bench_step.dependOn(&copy_sqlite.step);'''
assert old_sql in s, "sql"
s = s.replace(old_sql, new_sql)

old_edit = '''        const enlarge_stack = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; out=\x27$1\x27; eb=\x27${EDITBIN:-editbin}\x27; if command -v \x27$eb\x27 >/dev/null 2>&1; then \x27$eb\x27 /STACK:16777216 \x27$out\x27; fi", out });
        enlarge_stack.addFileArg(out);
        enlarge_stack.step.dependOn(&copy_sqlite.step);
        bench_step.dependOn(&enlarge_stack.step);'''
new_edit = '''        const enlarge_stack = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; out=\x27$1\x27; eb=\x27${EDITBIN:-editbin}\x27; if command -v \x27$eb\x27 >/dev/null 2>&1; then \x27$eb\x27 /STACK:16777216 \x27$out\x27; fi" });
        enlarge_stack.addFileArg(out);
        enlarge_stack.step.dependOn(&copy_sqlite.step);
        bench_step.dependOn(&enlarge_stack.step);'''
assert old_edit in s, "edit"
s = s.replace(old_edit, new_edit)

open(p, "w", encoding="utf-8").write(s)
print("fixed file-arg passing")
