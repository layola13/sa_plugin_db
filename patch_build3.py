p = "build.zig"
s = open(p, encoding="utf-8").read()
old = 'const sqlite_lib = b.option([]const u8, "sqlite-lib", "Path to the SQLite shared library used by SQLite control benchmarks.") orelse "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0";'
new = 'const sqlite_lib = b.option([]const u8, "sqlite-lib", "Path to the SQLite shared library used by SQLite control benchmarks.") orelse b.pathJoin(&.{ b.pathFromRoot("benchmark_test"), "sqlite3_runtime", "sqlite3.dll" });'
assert old in s, "old not found"
s = s.replace(old, new)
open(p, "w", encoding="utf-8").write(s)
print("default sqlite-lib updated")
