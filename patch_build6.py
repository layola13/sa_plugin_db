p = "build.zig"
s = open(p, encoding="utf-8").read()

old_db = '    const copy_db = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f "$1" "$2"", db_dll, out });'
new_db = '    const copy_db = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f \x27$1\x27 \x27$2\x27", db_dll, out });'
assert old_db in s, "db anchor"
s = s.replace(old_db, new_db)

old_sql = '    const copy_sqlite = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f "$1" "$2"", sqlite_lib, out });'
new_sql = '    const copy_sqlite = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; cp -f \x27$1\x27 \x27$2\x27", sqlite_lib, out });'
assert old_sql in s, "sql anchor"
s = s.replace(old_sql, new_sql)

old_edit = '        const enlarge_stack = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; out="$1"; eb="${EDITBIN:-editbin}"; if command -v "$eb" >/dev/null 2>&1; then "$eb" /STACK:16777216 "$out"; fi", out });'
new_edit = '        const enlarge_stack = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; out=\x27$1\x27; eb=\x27${EDITBIN:-editbin}\x27; if command -v \x27$eb\x27 >/dev/null 2>&1; then \x27$eb\x27 /STACK:16777216 \x27$out\x27; fi", out });'
assert old_edit in s, "edit anchor"
s = s.replace(old_edit, new_edit)

open(p, "w", encoding="utf-8").write(s)
print("fixed quote escaping")
