#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 - <<'PY'
import pathlib
import re
import sys

root = pathlib.Path.cwd()
build = root / "build.zig"
source = build.read_text()

match = re.search(r"const\s+abi_smoke_sources\s*=\s*\[_\]\[\]const\s+u8\s*\{(?P<body>.*?)\n\s*\};", source, re.S)
if not match:
    raise SystemExit("abi_smoke_sources list not found in build.zig")

listed = sorted(set(re.findall(r'"(benchmark_test/db_[^"]+_smoke\.sa)"', match.group("body"))))
actual = sorted(path.as_posix() for path in (root / "benchmark_test").glob("db_*_smoke.sa"))
actual = [pathlib.Path(path).relative_to(root).as_posix() for path in actual]

missing = sorted(set(actual) - set(listed))
extra = sorted(set(listed) - set(actual))

if missing or extra:
    if missing:
        print("db smoke files missing from abi_smoke_sources:", file=sys.stderr)
        for item in missing:
            print(f"  {item}", file=sys.stderr)
    if extra:
        print("abi_smoke_sources entries without matching files:", file=sys.stderr)
        for item in extra:
            print(f"  {item}", file=sys.stderr)
    print(f"actual={len(actual)} listed={len(listed)}", file=sys.stderr)
    raise SystemExit(1)

print(f"abi smoke coverage complete: files={len(actual)} listed={len(listed)}")
PY
