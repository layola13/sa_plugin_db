#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
sa_bin="${SA_PLUGIN_DB_SA_BIN:-sa}"
skip_build="${SA_PLUGIN_DB_SKIP_BUILD:-0}"

normalize_home_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        printf '%s' "$path"
    else
        printf '%s/%s' "$repo_root" "$path"
    fi
}

if [[ -z "${SA_PLUGINS_HOME:-}" ]]; then
    smoke_home="${SA_PLUGIN_DB_SMOKE_HOME:-$tmp_dir/sa_plugins_home}"
    export SA_PLUGINS_HOME="$(normalize_home_path "$smoke_home")"
elif [[ "$SA_PLUGINS_HOME" != /* ]]; then
    export SA_PLUGINS_HOME="$(normalize_home_path "$SA_PLUGINS_HOME")"
fi

if [[ "$skip_build" != "1" ]]; then
    cd "$repo_root"
    zig build >/dev/null
    SA_PLUGIN_DEV=1 "$sa_bin" plugin install --dev "$repo_root" >/dev/null
fi

cd "$tmp_dir"
cat > flash_sale.sadb-schema <<'SCHEMA'
#def MAX_ROWS = 8
#def COL_ID_STRIDE = 8 // u64
#def COL_PRICE_STRIDE = 4 // f32
SCHEMA

cat > rows.csv <<'CSV'
ID,PRICE
1,9.5
2,10.25
CSV

cat > rows2.csv <<'CSV'
ID,PRICE
3,11.75
CSV

SA_PLUGIN_DEV=1 "$sa_bin" db init flash_sale.sadb-schema | grep -F 'flash_sale.sai' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db ingest flash_sale rows.csv | grep -F 'row_count: 2' >/dev/null
cp flash_sale.manifest manifest.after_two

SA_PLUGIN_DEV=1 "$sa_bin" db ingest flash_sale rows2.csv | grep -F 'row_count: 3' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale | grep -F 'row_count: 3' >/dev/null
cp flash_sale.manifest manifest.after_three

# Simulate a crash that leaves the active manifest stale while newer versioned
# meta and segment artifacts reached disk. Recovery must select the newer commit.
cp manifest.after_two flash_sale.manifest
SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale | grep -F 'row_count: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db recover flash_sale | grep -F 'row_count: 3' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale | grep -F 'row_count: 3' >/dev/null

latest_meta="$(find . -maxdepth 1 -type f -name 'flash_sale.meta.*' -printf '%f\n' | sort -t. -k3,3n | tail -n 1)"
test -n "$latest_meta"
cp "$latest_meta" latest.meta.backup
latest_epoch="${latest_meta##*.}"
previous_epoch=$((latest_epoch - 1))
latest_meta_bytes="$(wc -c < "$latest_meta" | tr -d ' ')"
latest_meta_sha256="$(sha256sum "$latest_meta" | awk '{print $1}')"

# Simulate a transaction commit marker that reached disk while the active
# manifest stayed stale. Recovery must validate the marker and complete the
# committed transaction by publishing the marked meta.
cat > "flash_sale.tx.${latest_epoch}.commit" <<MARKER
{"magic":"sa-db-tx-commit","version":1,"table_name":"flash_sale","epoch":${latest_epoch},"meta_path":"${latest_meta}","meta_sha256":"${latest_meta_sha256}","meta_bytes":${latest_meta_bytes}}
MARKER
cp manifest.after_two flash_sale.manifest
SA_PLUGIN_DEV=1 "$sa_bin" db recover flash_sale | grep -F 'row_count: 3' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale | grep -F 'row_count: 3' >/dev/null

# Simulate an incomplete transaction where new artifacts and versioned meta
# reached disk but only the pending marker exists. Recovery must ignore that
# uncommitted epoch, keep the stale committed manifest, and remove the marker.
rm -f "flash_sale.tx.${latest_epoch}.commit"
cat > "flash_sale.tx.${latest_epoch}.pending" <<MARKER
{"magic":"sa-db-tx-pending","version":1,"table_name":"flash_sale","previous_epoch":${previous_epoch},"target_epoch":${latest_epoch}}
MARKER
cp manifest.after_two flash_sale.manifest
SA_PLUGIN_DEV=1 "$sa_bin" db recover flash_sale | grep -F 'row_count: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale | grep -F 'row_count: 2' >/dev/null
test ! -e "flash_sale.tx.${latest_epoch}.pending"

# Simulate a latest commit whose versioned meta is readable but one segment
# artifact is torn. Recovery must reject that candidate and fall back.
cp manifest.after_three flash_sale.manifest
latest_segment_path="$(jq -r '.segments[-1].files[0].path' "$latest_meta")"
test -n "$latest_segment_path"
test "$latest_segment_path" != "null"
printf 'corrupt\n' > "$latest_segment_path"
if SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale >verify_bad_segment.out 2>verify_bad_segment.err; then
    echo 'verify unexpectedly succeeded with corrupt latest segment' >&2
    exit 1
fi
SA_PLUGIN_DEV=1 "$sa_bin" db recover flash_sale | grep -F 'row_count: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale | grep -F 'row_count: 2' >/dev/null

# Simulate a torn/corrupt latest meta publish. Recovery must ignore that
# candidate and republish the previous highest valid committed epoch.
cp manifest.after_three flash_sale.manifest
printf '{not-json}\n' > "$latest_meta"
if SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale >verify_corrupt.out 2>verify_corrupt.err; then
    echo 'verify unexpectedly succeeded with corrupt active meta' >&2
    exit 1
fi
SA_PLUGIN_DEV=1 "$sa_bin" db recover flash_sale | grep -F 'row_count: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify flash_sale | grep -F 'row_count: 2' >/dev/null

cat > indexed_sale.sadb-schema <<'SCHEMA'
#def MAX_ROWS = 8
#def COL_ID_STRIDE = 8 // u64
#def COL_TOTAL_STRIDE = 8 // u64
SCHEMA

cat > indexed_rows.csv <<'CSV'
ID,TOTAL
1,100
2,200
CSV

SA_PLUGIN_DEV=1 "$sa_bin" db init indexed_sale.sadb-schema | grep -F 'indexed_sale.sai' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db ingest indexed_sale indexed_rows.csv | grep -F 'row_count: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db index-u64 indexed_sale 0 unique | grep -F 'row_count: 2' >/dev/null
indexed_meta="$(find . -maxdepth 1 -type f -name 'indexed_sale.meta.*' -printf '%f\n' | sort -t. -k3,3n | tail -n 1)"
test -n "$indexed_meta"
indexed_path="$(jq -r '.indexes[0].path' "$indexed_meta")"
test -n "$indexed_path"
test "$indexed_path" != "null"

# Simulate a torn latest index artifact. Recovery must skip the indexed epoch
# and republish the previous valid data epoch.
printf 'corrupt\n' > "$indexed_path"
if SA_PLUGIN_DEV=1 "$sa_bin" db verify indexed_sale >verify_bad_index.out 2>verify_bad_index.err; then
    echo 'verify unexpectedly succeeded with corrupt latest index' >&2
    exit 1
fi
SA_PLUGIN_DEV=1 "$sa_bin" db recover indexed_sale | grep -F 'row_count: 2' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify indexed_sale | grep -F 'row_count: 2' >/dev/null

# Build a public db.sal dictionary transaction smoke against the installed
# plugin, run it in this crash-smoke root, then tear the latest dictionary
# artifact. Recovery must skip that epoch and republish the prior valid table.
SA_PLUGIN_DEV=1 "$sa_bin" build-exe "$repo_root/benchmark_test/db_tx_dict_smoke.sa" -o dict_seed.out --no-incremental >/dev/null
./dict_seed.out
dict_meta="$(find . -maxdepth 1 -type f -name 'tx_dict_members.meta.*' -printf '%f\n' | sort -t. -k3,3n | tail -n 1)"
test -n "$dict_meta"
dict_path="$(jq -r '.dicts[0].path' "$dict_meta")"
test -n "$dict_path"
test "$dict_path" != "null"

# Simulate a torn latest dictionary artifact. Recovery must reject that
# otherwise current epoch and fall back to the pre-dictionary commit.
printf 'corrupt\n' > "$dict_path"
if SA_PLUGIN_DEV=1 "$sa_bin" db verify tx_dict_members >verify_bad_dict.out 2>verify_bad_dict.err; then
    echo 'verify unexpectedly succeeded with corrupt latest dictionary' >&2
    exit 1
fi
SA_PLUGIN_DEV=1 "$sa_bin" db recover tx_dict_members | grep -F 'row_count: 0' >/dev/null
SA_PLUGIN_DEV=1 "$sa_bin" db verify tx_dict_members | grep -F 'row_count: 0' >/dev/null

echo 'db crash recovery smoke passed'
