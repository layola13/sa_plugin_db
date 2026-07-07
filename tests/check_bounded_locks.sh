#!/usr/bin/env bash
set -euo pipefail

build_path="${1:-build.zig}"

if [[ -z "$build_path" || ! -f "$build_path" ]]; then
    echo "build.zig is required for bounded lock checks" >&2
    exit 1
fi

python3 - "$build_path" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text()
matches = list(re.finditer(r'"flock"', source))

if not matches:
    raise SystemExit(f"no flock calls found in {path}")

bad = []
for match in matches:
    window = source[match.start():match.start() + 160]
    if not re.match(r'"flock"\s*,\s*"-w"\s*,\s*lock_wait_seconds_arg\s*,', window):
        line_no = source.count("\n", 0, match.start()) + 1
        line = source[source.rfind("\n", 0, match.start()) + 1:source.find("\n", match.start())]
        bad.append(f"{line_no}: {line.strip()}")

if bad:
    details = "\n".join(bad)
    raise SystemExit(f"unbounded or nonstandard flock calls in {path}:\n{details}")

print(f"bounded lock guard passed: flock_calls={len(matches)} all use -w lock_wait_seconds_arg")
PY
