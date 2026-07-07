#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 && $# -ne 2 && $# -ne 4 && $# -ne 5 ]]; then
    echo 'usage: check_manifest_layout.sh <sap.json> [installed-current-dir [source-db.sai source-db.sal [source-libdb.so]]]' >&2
    exit 2
fi

manifest="$1"
installed_dir="${2:-}"
source_sai="${3:-}"
source_sal="${4:-}"
source_lib="${5:-}"

if [[ ! -f "$manifest" ]]; then
    echo "missing manifest: $manifest" >&2
    exit 2
fi

jq -e '
  .schema == "sa.plugin/1" and
  .name == "db" and
  .version == "0.1.0" and
  .source.type == "local" and
  .source.path == "." and
  .abi.plugin == 1 and
  .abi.symbols == "db.sai" and
  .artifacts."linux-x86_64".path == "zig-out/lib/libdb.so" and
  .interfaces.sai.path == "db.sai" and
  .interfaces.sal.path == "db.sal" and
  .skills == ["database"] and
  .dependencies == {} and
  (.permissions.net | length) == 0 and
  (.permissions.env | length) == 0 and
  .permissions.process.spawn == false and
  (.permissions.process.exec | length) == 0 and
  (.permissions.fs | length) == 4 and
  ([.permissions.fs[].op] | sort) == ["create", "delete", "read", "write"] and
  all(.permissions.fs[]; .path == "$PROJECT/**")
' "$manifest" >/dev/null

if [[ -n "$installed_dir" ]]; then
    test -d "$installed_dir"
    test -f "$installed_dir/libdb.so"
    test -f "$installed_dir/sap.json"
    test -f "$installed_dir/sa/db.sai"
    test -f "$installed_dir/sa/db.sal"
    test -f "$installed_dir/permissions.lock"
    if ! cmp -s "$manifest" "$installed_dir/sap.json"; then
        echo 'installed sap.json differs from source manifest' >&2
        exit 1
    fi
    if [[ -n "$source_sai" ]]; then
        test -f "$source_sai"
        test -f "$source_sal"
        if ! cmp -s "$source_sai" "$installed_dir/sa/db.sai"; then
            echo 'installed db.sai differs from source db.sai' >&2
            exit 1
        fi
        if ! cmp -s "$source_sal" "$installed_dir/sa/db.sal"; then
            echo 'installed db.sal differs from source db.sal' >&2
            exit 1
        fi
    fi
    if [[ -n "$source_lib" ]]; then
        test -f "$source_lib"
        if ! cmp -s "$source_lib" "$installed_dir/libdb.so"; then
            echo 'installed libdb.so differs from source artifact libdb.so' >&2
            exit 1
        fi
    fi

    expected_permissions_hash="$(jq -c '.permissions' "$manifest" | tr -d '\n' | sha256sum | awk '{print $1}')"
    empty_graph_hash="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    lock="$installed_dir/permissions.lock"
    lock_value() {
        local key="$1"
        awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2)}' "$lock"
    }

    [[ "$(lock_value schema)" == "sa.permissions/1" ]]
    [[ "$(lock_value plugin)" == "db" ]]
    [[ "$(lock_value version)" == "0.1.0" ]]
    [[ "$(lock_value permissions_sha256)" == "$expected_permissions_hash" ]]
    [[ "$(lock_value dependency_graph_sha256)" == "$empty_graph_hash" ]]
    [[ "$(lock_value requires_confirmation)" == "true" ]]
    [[ "$(lock_value confirmed)" == "false" ]]
    [[ "$(lock_value artifact_scan)" == "dynamic-imports" ]]
    [[ "$(lock_value sandbox_enforced)" == "false" ]]
fi

echo 'db manifest and install layout are valid'
