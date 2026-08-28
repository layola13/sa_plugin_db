#!/usr/bin/env bash
set +e
export SA_PLUGIN_DEV=1
export SA_DB_UNSAFE_NO_SYNC=1
export SA_PLUGINS_HOME="D:/projects/sla/sa_plugin_db/.zig-cache/db-bench-compare-home"
DB_OUT="D:/projects/sla/sa_plugin_db/.zig-cache/o/8de9626f1c4bfae7acf9e813d6e83b02/db_erp_indexed_write_bench.out"
SQL_OUT="D:/projects/sla/sa_plugin_db/.zig-cache/o/cf787454fdf64656c3f6b4a5ca31fa31/sqlite_erp_indexed_write_bench.out"
for i in 1 2 3; do
  cd "D:/projects/sla/sa_plugin_db"
  rm -rf benchmark_test/.bench_erp_indexed_db
  echo "=== DB RUN $i ==="
  "$DB_OUT" | grep -E '_ns=|indexed_.*_rows='
  TMP=$(mktemp -d)
  echo "=== SQLITE RUN $i ==="
  ( cd "$TMP" && "$SQL_OUT" ) | grep -E '_ns=|indexed_.*_rows='
  rm -rf "$TMP"
done
