#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo 'usage: check_cli_surface.sh <sa-bin> <src/plugin.zig>' >&2
    exit 2
fi

sa_bin="$1"
plugin_zig="$2"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ ! -f "$plugin_zig" ]]; then
    echo "missing plugin source: $plugin_zig" >&2
    exit 2
fi

python3 - "$plugin_zig" > "$tmp_dir/expected.txt" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
section = re.search(r'\.name\s*=\s*"database"(?P<body>.*?)\.items\s*=\s*&\.\{(?P<items>.*?)\n\s*\}', source, re.S)
if not section:
    raise SystemExit("database skill section not found in plugin.zig")
items = re.findall(r'"(db [^"]+)"', section.group("items"))
if not items:
    raise SystemExit("no database skill items found in plugin.zig")
for item in items:
    print(item)
PY

SA_PLUGIN_DEV=1 "$sa_bin" skills > "$tmp_dir/skills.txt"
SA_PLUGIN_DEV=1 "$sa_bin" skills --json > "$tmp_dir/skills.json"

python3 - "$tmp_dir/skills.txt" > "$tmp_dir/actual.txt" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
try:
    start = lines.index("database")
except ValueError:
    raise SystemExit("database skill section missing from sa skills output")

items = []
for line in lines[start + 1:]:
    if not line:
        continue
    if line.startswith("summary:"):
        continue
    if line.startswith("- "):
        items.append(line[2:])
        continue
    break

if not items:
    raise SystemExit("database skill section has no items in sa skills output")
for item in items:
    print(item)
PY

if ! cmp -s "$tmp_dir/expected.txt" "$tmp_dir/actual.txt"; then
    echo 'database CLI skill surface mismatch' >&2
    echo 'expected from src/plugin.zig:' >&2
    sed 's/^/  /' "$tmp_dir/expected.txt" >&2
    echo 'actual from sa skills:' >&2
    sed 's/^/  /' "$tmp_dir/actual.txt" >&2
    diff -u "$tmp_dir/expected.txt" "$tmp_dir/actual.txt" >&2 || true
    exit 1
fi

python3 - "$tmp_dir/skills.json" > "$tmp_dir/actual_json.txt" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
skills = data.get("skills")
if not isinstance(skills, list):
    raise SystemExit("sa skills --json output missing skills array")

database = None
for skill in skills:
    if isinstance(skill, dict) and skill.get("name") == "database":
        database = skill
        break
if database is None:
    raise SystemExit("database skill section missing from sa skills --json output")

items = database.get("items")
if not isinstance(items, list) or not all(isinstance(item, str) for item in items):
    raise SystemExit("database skill items in sa skills --json are not a string array")
if not items:
    raise SystemExit("database skill section has no items in sa skills --json output")
for item in items:
    print(item)
PY

if ! cmp -s "$tmp_dir/expected.txt" "$tmp_dir/actual_json.txt"; then
    echo 'database JSON CLI skill surface mismatch' >&2
    echo 'expected from src/plugin.zig:' >&2
    sed 's/^/  /' "$tmp_dir/expected.txt" >&2
    echo 'actual from sa skills --json:' >&2
    sed 's/^/  /' "$tmp_dir/actual_json.txt" >&2
    diff -u "$tmp_dir/expected.txt" "$tmp_dir/actual_json.txt" >&2 || true
    exit 1
fi

echo "database CLI skill surface matches text/json: items=$(wc -l < "$tmp_dir/expected.txt")"
