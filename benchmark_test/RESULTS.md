# db 插件会员库性能评估

测试对象：`/home/vscode/projects/sa_plugins/sa_plugin_db/sap.json`，SA 版本 `sa 0.0.3.3`。所有测试程序均用 SA 编写；SQLite 对照通过 SA `@extern sqlite3_*` 调用系统 SQLite。

## 场景

- 数据量：50,000 行会员数据。
- 字段：`id`、`plan`、`status`、`points`，均按 `u64` 处理。
- 单线程操作：新建/初始化表、批量插入、通过 read handle 做 `SUM(points)`、全量 `points += 5`、再次 SUM、`plan = 1` 计数、compact/vacuum、verify/integrity check。
- 并发操作：4 个 worker，100 次全表 SUM 查询；4 个 worker，各插入 12,500 行，合计 50,000 行。
- ERP workflow：1,024 个客户、512 个产品、8,192 个订单、32,768 条订单明细、16,384 条库存流水、8,192 张发票。覆盖字典状态、`i64` decimal/date 字段、`u64`、`u64_pair` 和 `u64_i64_pair` 索引、子行查询、客户/日期和状态/到期日复合过滤、计数、projection、跨多表 verify。
- 正确性校验：单线程要求 `rows=50000`、`sum_before=12500250000`、`sum_after=12500500000`、`plan_one_count=12500`、`updated_rows=50000`；并发要求 query/insert ok 均为 1，插入行数 50,000。

## 命令

db 插件：

```bash
sa build-exe db_member_bench.sa -o db_member_bench.out --no-incremental
./db_member_bench.out

sa build-exe db_concurrent_bench.sa -o db_concurrent_bench.out --no-incremental
./db_concurrent_bench.out

sa build-exe db_erp_workflow_bench.sa -o db_erp_workflow_bench.out --no-incremental
./db_erp_workflow_bench.out
```

SQLite 对照：

```bash
rm -rf sqlite_link_std
mkdir -p sqlite_link_std
(cd sqlite_link_std && ar x /home/vscode/.sa/std/libsa_std.a)
objcopy --redefine-sym sqlite3_prepare=sa_std_stub_sqlite3_prepare \
  --redefine-sym sqlite3_step=sa_std_stub_sqlite3_step \
  --redefine-sym sqlite3_finalize=sa_std_stub_sqlite3_finalize \
  sqlite_link_std/libsa_std.a.o
(cd sqlite_link_std && ar rcs libsa_std_no_sqlite_stub.a *.o)

sa build-obj sqlite_member_bench.sa -o sqlite_member_bench.o --no-incremental
zig cc -O1 sqlite_member_bench.o sqlite_link_std/libsa_std_no_sqlite_stub.a \
  /lib/x86_64-linux-gnu/libsqlite3.so.0 \
  -Wl,-rpath,/lib/x86_64-linux-gnu -o sqlite_member_bench.out
./sqlite_member_bench.out

sa build-obj sqlite_concurrent_bench.sa -o sqlite_concurrent_bench.o --no-incremental
zig cc -O1 sqlite_concurrent_bench.o sqlite_link_std/libsa_std_no_sqlite_stub.a \
  /lib/x86_64-linux-gnu/libsqlite3.so.0 \
  -Wl,-rpath,/lib/x86_64-linux-gnu -o sqlite_concurrent_bench.out
./sqlite_concurrent_bench.out

sa build-obj sqlite_erp_workflow_bench.sa -o sqlite_erp_workflow_bench.o --no-incremental
zig cc -O1 sqlite_erp_workflow_bench.o sqlite_link_std/libsa_std_no_sqlite_stub.a \
  /lib/x86_64-linux-gnu/libsqlite3.so.0 \
  -Wl,-rpath,/lib/x86_64-linux-gnu -o sqlite_erp_workflow_bench.out
./sqlite_erp_workflow_bench.out
```

说明：`libsa_std.a` 当前仍导出 `sqlite3_prepare/sqlite3_step/sqlite3_finalize` stub，会覆盖系统 SQLite 同名符号。SQLite 对照使用重命名后的本地 std archive；当前 archive 已包含 pthread host 符号，不需要再显式编入 `sa_pthread_host.c`。

db 插件旧的 direct query ABI 已删除；SA-facing 查询接口现在只开放 read-handle API：`sa_db_open_read_table`、`sa_db_close_read_table`、`sa_db_sum_u64_handle`、`sa_db_count_u64_eq_handle`、`sa_db_count_u64_cmp_handle`、`sa_db_min_u64_handle`、`sa_db_max_u64_handle`。

## 单线程结果

5 轮运行取中位数，完整原始输出见 `db_member_bench_runs.txt` 和 `sqlite_member_bench_runs.txt`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| create/init | 6.711 ms | 0.596 ms | SQLite 约 11.3x |
| prepare columns | 1.018 ms | N/A | db 专有成本 |
| bulk insert | 19.012 ms | 41.081 ms | db 插件约 2.2x |
| sum before | 5.359 ms | 3.256 ms | SQLite 约 1.6x |
| update all | 8.897 ms | 9.838 ms | db 插件约 1.1x |
| sum after | 3.683 ms | 2.803 ms | SQLite 约 1.3x |
| count plan=1 | 1.108 ms | 2.253 ms | db 插件约 2.0x |
| compact/vacuum | 20.293 ms | 5.597 ms | SQLite 约 3.6x |
| verify/integrity | 11.624 ms | 3.518 ms | SQLite 约 3.3x |

## 并发结果

5 轮运行取中位数，完整原始输出见 `db_concurrent_bench_runs.txt` 和 `sqlite_concurrent_bench_runs.txt`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| serial query, 100x SUM | 122.111 ms | 308.089 ms | db 插件约 2.5x |
| concurrent query, 4x25 SUM | 48.385 ms | 120.165 ms | db 插件约 2.5x |
| concurrent insert, 4x12,500 rows | 55.618 ms | 90.713 ms | db 插件约 1.6x |

## ERP workflow 结果

7 轮运行取中位数。两侧正确性输出均为 `order_line_total=4`、`customer_order_total=8`、`due_invoice_total=640`、`inventory_move_total=32`、`project_written_rows=4`、`paid_invoice_count=4096`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init 6 ERP tables | 153.576 ms | 1.301 ms | SQLite 约 118.0x |
| ingest ERP rows | 131.877 ms | 93.332 ms | SQLite 约 1.4x |
| build ERP indexes | 175.708 ms | 19.449 ms | SQLite 约 9.0x |
| order lines by order id | 0.019 ms | 0.052 ms | db 插件约 2.8x |
| project order line columns | 0.005 ms | 0.031 ms | db 插件约 5.8x |
| orders by customer/date | 0.006 ms | 0.028 ms | db 插件约 4.6x |
| paid due invoices by status/date | 0.010 ms | 0.248 ms | db 插件约 25.4x |
| inventory moves by product id | 0.007 ms | 0.027 ms | db 插件约 3.9x |
| verify/integrity | 147.362 ms | 38.938 ms | SQLite 约 3.8x |

这个 workload 固定住中小型 ERP 常见访问形状：订单明细、客户/日期订单、状态/到期日发票、库存流水、状态计数和列表 projection。当前结论是：SQLite 的建库、建索引和 integrity check 明显更成熟；db 插件的已打开快照索引读路径在 ERP 列表查询上更快。后续优化并发查询、mmap snapshot、索引规划或恢复机制时，应继续跑这个基准。

## 结论

- 查询速度：单次 read-handle SUM 仍会计入打开快照成本，SQLite 更快；复用 read-handle 的串行/并发全表 SUM，db 插件明显更快。
- ERP 列表查询：订单明细、客户/日期订单、状态/到期日发票、库存流水和 projection 当前都是 db 插件更快。
- 并发插入：db 插件更快，但当前实现用进程内写互斥保证正确性，属于串行化 writer，不等价于 SQLite 的事务/WAL 能力。
- 批量写入和全量列更新：db 插件更快，主要受益于列式 raw column ingest。
- 初始化、建索引、compact、verify/integrity：SQLite 更成熟也更快。

综合回答“哪个最快”：并发查询和并发插入在本 benchmark 都是 db 插件更快；如果需要 ACID、索引、SQL、崩溃恢复，仍应选 SQLite。
