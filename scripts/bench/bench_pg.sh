#!/bin/bash
# PostgreSQL reference bench for the sa_plugin_db concurrency
# report. Spins up a PRIVATE throwaway cluster (initdb under
# /tmp, unix socket only, listen_addresses=''), benches it with
# pgbench, then stops and deletes it. Never touches any other
# PostgreSQL instance or its data.
# Usage: bench_pg.sh <out-dir>
set -u
OUT="${1:?output dir}"
mkdir -p "$OUT"
PGBIN=/usr/lib/postgresql/16/bin
PGROOT=/tmp/dbconc-pg
PORT=54331
rm -rf "$PGROOT"
mkdir -p "$PGROOT"
chown postgres:postgres "$PGROOT"

su postgres -c "$PGBIN/initdb -D $PGROOT/data -U postgres" > "$OUT/pg_initdb.log" 2>&1 || exit 1
su postgres -c "$PGBIN/pg_ctl -D $PGROOT/data -l $PGROOT/server.log -o '-p $PORT -k $PGROOT -c listen_addresses=' -w start" >> "$OUT/pg_initdb.log" 2>&1 || exit 1

PSQL="$PGBIN/psql -h $PGROOT -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
su postgres -c "$PSQL -c 'CREATE DATABASE bench'" || exit 1
su postgres -c "$PSQL -d bench -c 'CREATE TABLE t (id int PRIMARY KEY, val int)' -c 'INSERT INTO t SELECT g, 1 FROM generate_series(0, 19999) g' -c 'CREATE TABLE w (id int PRIMARY KEY, val int)' -c 'INSERT INTO w SELECT g, 1 FROM generate_series(0, 1999) g'" || exit 1

echo "SELECT val FROM t WHERE id = 12345;" > "$PGROOT/point.sql"
echo "SELECT sum(val) FROM t;" > "$PGROOT/readsum.sql"
echo "UPDATE w SET val = 1;" > "$PGROOT/write.sql"
chown postgres:postgres "$PGROOT"/*.sql

RESULTS="$OUT/results_pg.csv"
: > "$RESULTS"
RAW="$OUT/pg_raw"
mkdir -p "$RAW"
# pgbench runs as postgres and writes its per-transaction logs here.
chown postgres:postgres "$RAW"

run_pgbench() {
  # $1 scenario $2 clients $3 jobs $4 seconds $5 round
  local scenario="$1" clients="$2" jobs="$3" seconds="$4" round="$5"
  local logbase="$RAW/${scenario}_c${clients}_r${round}"
  su postgres -c "cd $PGROOT && $PGBIN/pgbench -h $PGROOT -p $PORT -U postgres -d bench -c $clients -j $jobs -T $seconds -l --log-prefix=$logbase -f $PGROOT/$scenario.sql" > "$logbase.summary" 2>&1
  python3 - "$scenario" "$clients" "$logbase" >> "$RESULTS" <<'PYEOF'
import glob, sys
scenario, clients, logbase = sys.argv[1], sys.argv[2], sys.argv[3]
lat = []
for path in glob.glob(logbase + "*"):
    if path.endswith(".summary"):
        continue
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) >= 3:
                lat.append(int(parts[2]))  # latency, microseconds
lat.sort()
ops = len(lat)
summary = open(logbase + ".summary").read()
tps = 0.0
for line in summary.splitlines():
    if line.startswith("tps ="):
        tps = float(line.split("=")[1].split("(")[0].strip())
        break
p50 = lat[(len(lat) * 50) // 100] if lat else 0
p99 = lat[min(len(lat) - 1, (len(lat) * 99) // 100)] if lat else 0
wall_ms = ops / tps * 1000.0 if tps > 0 else 0.0
print(f"{scenario},{clients},{ops},{wall_ms:.1f},{tps:.1f},{p50},{p99},0")
PYEOF
}

for round in 1 2 3; do
  for clients in 1 2 4 8 16 32; do
    jobs=$clients; if [ "$jobs" -gt 8 ]; then jobs=8; fi
    run_pgbench readsum "$clients" "$jobs" 8 "$round"
  done
  for clients in 1 4 8; do
    run_pgbench point "$clients" "$clients" 8 "$round"
  done
  run_pgbench write 1 1 8 "$round"
done

su postgres -c "$PGBIN/pg_ctl -D $PGROOT/data -m fast -w stop" >> "$OUT/pg_initdb.log" 2>&1
rm -rf "$PGROOT"
echo "PG_BENCH_DONE $OUT"
