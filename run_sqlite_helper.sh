#!/usr/bin/env bash
export SA_PLUGIN_DEV=1
export SA_DB_UNSAFE_NO_SYNC=1
export SA_PLUGINS_HOME="D:/projects/sla/sa_plugin_db/.zig-cache/db-bench-compare-home"
rm -rf /tmp/sa-db-sqlite-control-*
OUT="$1"
"$OUT" > bench_run_stdout.log 2> bench_run_stderr.log
echo "EXIT=$?" >> bench_run_stdout.log
