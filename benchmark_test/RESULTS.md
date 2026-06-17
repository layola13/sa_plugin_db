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

db 插件旧的 direct query ABI 已删除；SA-facing 查询接口现在只开放 read-handle API：`sa_db_open_read_table`、`sa_db_close_read_table`、`sa_db_sum_u64_handle`、`sa_db_sum_i64_handle`、`sa_db_group_sum_i64_by_u64_handle`、`sa_db_group_rows_sum_i64_by_u64_handle`、`sa_db_group_sum_i64_by_u64_sorted_handle`、`sa_db_group_rows_sum_i64_by_u64_sorted_handle`、`sa_db_group_stats_i64_by_u64_handle`、`sa_db_group_rows_stats_i64_by_u64_handle`、`sa_db_group_stats_i64_by_u64_sorted_handle`、`sa_db_group_rows_stats_i64_by_u64_sorted_handle`、`sa_db_count_u64_eq_handle`、`sa_db_count_u64_cmp_handle`、`sa_db_min_u64_handle`、`sa_db_max_u64_handle`。

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

当前并发写对比分两条路径。三套并发基准都改成了独立 root：

- `db_concurrent_bench.sa` -> `.bench_raw`
- `db_coltx_concurrent_bench.sa` -> `.bench_coltx`
- `sqlite_concurrent_bench.sa` -> `.bench_sqlite`

这样可以避免历史工件、WAL/SHM 侧文件和别的 benchmark 互相污染。

- `db_concurrent_bench.sa`：原始 `sa_db_ingest_columns` 并发调用
- `db_coltx_concurrent_bench.sa`：新的 `sa_db_coltx_*` 列批量 session，并行 `add_columns`，最后各线程单次 `commit`

原始 `ingest_columns` 路径的本轮单轮结果：

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| serial query, 100x SUM | 224.297 ms | 599.965 ms | db 插件约 2.7x |
| concurrent query, 4x25 SUM | 287.438 ms | 606.453 ms | db 插件约 2.1x |
| concurrent insert, 4x12,500 rows | 109.378 ms | 214.685 ms | db 插件约 2.0x |

新的 `coltx` 路径这轮单轮结果：

| 操作 | db coltx | SQLite | 最快 |
| --- | ---: | ---: | --- |
| concurrent insert, 4x12,500 rows | 92.779 ms | 214.685 ms* | db coltx 约 2.3x |

当前单轮输出：

- db raw: `(224.297, 287.438, 109.378) ms`
- db coltx: `92.779 ms` concurrent insert
- sqlite: `(599.965, 606.453, 214.685) ms`

`*` SQLite 这轮只跑了 raw 对照程序；它没有单独区分 raw ingest 和 coltx，因为两者都是同一条 SQLite 并发事务插入路径。

更早一轮在进一步把 snapshot 的 segment/index 热路径切到 `mmap` 之后，重建 db raw
benchmark 的输出为：

- db mmap raw: `(145.666, 146.215, 89.898) ms`

继续移除 `sa_db_open_read_table` 上的全局 `mutation_mutex` 之后，重建 db raw
benchmark 的输出为：

- db mmap raw no-open-lock: `(135.331, 146.660, 95.997) ms`

这一轮重新复跑了 db raw、db coltx 和 SQLite raw。SQLite 对照源码仍需走手工 extern
link 流程；在当前环境里系统只提供 `/lib/x86_64-linux-gnu/libsqlite3.so.0`，没有
`libsqlite3.so` 开发链接名，因此 `zig cc` 需要显式传入该绝对路径。

本轮并发测试都成功，没有出现 `VerifyFailed`、`CursorOverflow` 或 `NotFound`。

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

## ERP indexed append 结果

2026-06-17 复跑 `db_erp_indexed_write_bench.sa` 和 `sqlite_erp_indexed_write_bench.sa`。两侧正确性输出一致：`indexed_order_rows=8448`、`indexed_line_rows=33792`、`indexed_invoice_rows=8448`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 150.696 ms | 5.315 ms | SQLite 约 28.4x |
| baseline ingest before indexes | 68.151 ms | 74.059 ms | db 插件约 1.1x |
| build baseline indexes | 129.139 ms | 27.890 ms | SQLite 约 4.6x |
| append with tx + incremental indexes | 53.742 ms | 5.063 ms | SQLite 约 10.6x |
| append with coltx + incremental indexes | 52.369 ms | 5.063 ms* | SQLite 约 10.3x |
| verify/integrity | 127.625 ms | 37.026 ms | SQLite 约 3.4x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态。

和上面旧的 ERP workflow 中位数相比，db 侧 `build ERP indexes` 从 `175.708 ms` 降到 `129.139 ms`，约改善 `26.5%`。更重要的是，这轮已经把带二级索引的 ERP 追加写单独拆出来，db 侧 append 成本不再混在“全量 ingest + 全量建索引”里：纯事务追加约 `53.742 ms`，`coltx` 追加约 `52.369 ms`。这证明 append-only 增量索引路径已经生效，但和 SQLite 当前仍有数量级差距，下一步该继续压缩 pair/blob 类索引 merge 的常数成本、文件 I/O 次数和 verify/manifest 写入开销。

2026-06-18 继续把增量 append merge 里的“旧 index 文件读取”从 `readFileAlloc` 改成 `mmap` 只读映射后，重新顺序跑了 3 次 db 和 3 次 SQLite 对照。两侧正确性输出仍一致：`8448 / 33792 / 8448`。

| 操作 | db 插件中位数 | SQLite 中位数 | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 118.213 ms | 0.921 ms | SQLite 约 128.3x |
| baseline ingest before indexes | 71.843 ms | 61.504 ms | SQLite 约 1.2x |
| build baseline indexes | 132.000 ms | 18.490 ms | SQLite 约 7.1x |
| append with tx + incremental indexes | 52.465 ms | 3.620 ms | SQLite 约 14.5x |
| append with coltx + incremental indexes | 48.921 ms | 3.620 ms* | SQLite 约 13.5x |
| verify/integrity | 125.894 ms | 33.819 ms | SQLite 约 3.7x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态。

相对 2026-06-18 此前那组顺序重跑的 db 中位数（`build ~= 166.1 ms`、`tx ~= 66.4 ms`、`coltx ~= 66.5 ms`），这次 `mmap` 读取旧 index 文件后，db 侧 `tx` append 中位数降到 `52.465 ms`，约改善 `20.9%`；`coltx` append 中位数降到 `48.921 ms`，约改善 `26.4%`。`build` 中位数也回到 `132.000 ms`，接近 2026-06-17 那轮较好的基线。这个收益和当前 workload 是对得上的，因为 ERP indexed append 路径的热点之一就是每个增量 merge 前先把既有 index 文件完整读入 heap。

## 结论

- 查询速度：复用 read-handle 的 100 次全表 SUM，db 插件在串行和并发查询下都明显快于 SQLite。
- `mmap` snapshot 继续降低了 db 自身的 read-handle 查询成本，尤其并发 SUM 改善明显。
- 读句柄打开不再被全局 mutation 锁阻塞；活跃写事务期间也能打开已提交快照读取。
- 并发插入：本轮原始 `sa_db_ingest_columns` 和新的 `sa_db_coltx_*` 批量列 session 都快于 SQLite，其中 `coltx` 最快。
- 新增的 ABI 修复把 `sa_db_coltx_add_columns` 从“持有全局 handle mutex 执行整段 staging I/O”改成了带引用计数的共享获取，直接改善了多 session 并发追加。
- 批量写入和全量列更新：db 插件更快，主要受益于列式 raw column ingest。
- 初始化、建索引、compact、verify/integrity：SQLite 更成熟也更快。
- 带二级索引的 ERP append-only 写入现在已经走增量索引维护，db 不再为这条路径付出整表 `rebuildIndexes()` 的成本；相对旧 ERP workflow 里的全量建索引阶段，db 侧建索引成本已经明显下降。
- 之前出现的并发失败，主要是 benchmark 工件共享导致的污染，不是当前这轮隔离结果里的稳定行为。

综合回答“哪个最快”：当前这轮 benchmark 里，串行查询、并发查询、原始并发插入、`coltx` 并发插入，都是 db 更快；其中并发插入最快的是 `coltx`。但这组并发插入仍然是无显式二级索引的 workload，带主键/二级索引的 ERP 写入对照还需要单独补基准。
