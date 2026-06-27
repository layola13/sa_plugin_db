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

新的 `coltx` 路径单轮结果：

| 操作 | db coltx | SQLite | 最快 |
| --- | ---: | ---: | --- |
| concurrent insert, 4x12,500 rows | 92.779 ms | 214.685 ms* | db coltx 约 2.3x |

当前单轮输出：

- db raw: `(160.351, 176.853, 113.260) ms`
- db coltx: `(160.758, 137.739, 86.718) ms`
- sqlite: `(365.402, 192.302, 89.339) ms`

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

2026-06-18 再次按隔离 root 顺序重跑 3 次 db raw、3 次 db coltx 和 3 次 SQLite
raw，对应中位数如下：

| 操作 | db raw 中位数 | db coltx 中位数 | SQLite 中位数 | 最快 |
| --- | ---: | ---: | ---: | --- |
| serial 100x SUM | 167.317 ms | 143.751 ms | 338.595 ms | db coltx |
| concurrent 4x25 SUM | 157.531 ms | 160.721 ms | 197.866 ms | db raw |
| concurrent insert, 4x12,500 rows | 95.736 ms | 72.192 ms | 108.089 ms | db coltx |

这组 3-run 样本说明三件事：

- benchmark root 隔离后，之前那种工件/WAL 污染没有再出现；
- `sa_db_open_read_table` 去掉全局 `mutation_mutex` 后，db 侧 read-handle 查询依旧稳定快于 SQLite；
- `sa_db_coltx_add_columns` 改成共享句柄锁加 refcount 后，多 session 并发追加的中位数已经压到 raw ingest 之下。

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

2026-06-18 继续把“同表多索引创建”从 5 次独立 `sa_db_create_*_index` 调用收敛为按表批量 `sa_db_create_indexes` 调用后，重新构建 dev 插件并顺序各跑 1 次 db / SQLite indexed ERP append benchmark。两侧正确性输出仍一致：`8448 / 33792 / 8448`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 129.715 ms | 1.976 ms | SQLite 约 65.6x |
| baseline ingest before indexes | 77.508 ms | 68.214 ms | SQLite 约 1.1x |
| build baseline indexes | 92.848 ms | 20.900 ms | SQLite 约 4.4x |
| append with tx + incremental indexes | 37.086 ms | 3.932 ms | SQLite 约 9.4x |
| append with coltx + incremental indexes | 42.406 ms | 3.932 ms* | SQLite 约 10.8x |
| verify/integrity | 71.480 ms | 32.456 ms | SQLite 约 2.2x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态。

这一步的收益比前两轮更直接：相对前一组 db 单轮数据（`build ~= 133.5 ms`、`tx ~= 49.7 ms`、`coltx ~= 55.3 ms`、`verify ~= 137.6 ms`），批量建索引把 `build` 再压低约 `30.5%`，`tx` append 压低约 `25.4%`，`coltx` append 压低约 `23.3%`，`verify` 压低约 `48.1%`。原因也和 benchmark 结构一致：`orders`、`lines`、`invoices` 三张表现在只需要 3 次建索引事务，而不是为 `lines` 和 `invoices` 各自重复 load meta、写 manifest、刷新 epoch 两次。即便如此，SQLite 在 indexed ERP 写入链路上仍然全面领先，说明后续还要继续压缩 init/verify 常数开销，以及 append merge 内部 pair-index 维护的成本。

2026-06-27 在 lazy append index maintenance、事务字典缓冲、批量 `dict intern many` 之后，继续加入 unsafe init 延迟空 meta 持久化，以及“同进程 init 后首次写入”直接复用内存里的初始 `TableMeta`。随后在 indexed ERP benchmark 中撞出一个真实稳定性问题：`sa_db_init_schema` 用临时 arena 初始化时，unsafe init cache 直接保存了 arena 生命周期内的 `TableMeta`，首个写入路径可能在 `unsafeInitCacheDelete()` 比较缓存 key 时踩到悬垂内存并崩溃。修正后，cache 现在统一复制到独立长期 allocator 上，并新增了“init allocator teardown 后再 ingest”回归测试。

同日继续把真正的首写路径再顺了一次：unsafe 模式下 `loadWritableMeta()` 不再先经 `loadActiveMeta()` 做一次 `unsafeInitCachePeek()`，而是优先直接 `unsafeInitCacheTake()`；`insertRawRow()` 也改成一次 writable meta 装载后直接落到共享 append helper，避免首写前额外重复装载 meta。随后重新顺序跑了 5 次 db 和 5 次 SQLite 对照。两侧正确性输出仍一致：`8448 / 33792 / 8448`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 1.461-2.482 ms, 中位数 1.545 ms | 0.791-1.312 ms, 中位数 1.065 ms | SQLite |
| baseline ingest before indexes | 4.659-6.454 ms, 中位数 5.313 ms | 63.791-110.798 ms, 中位数 70.704 ms | db 插件约 13.3x |
| build baseline indexes | 8.518-12.136 ms, 中位数 9.845 ms | 22.207-29.889 ms, 中位数 23.896 ms | db 插件约 2.4x |
| append with tx + incremental indexes | 2.188-2.562 ms, 中位数 2.350 ms | 4.628-7.226 ms, 中位数 5.141 ms* | db 插件约 2.2x |
| append with coltx + incremental indexes | 1.604-1.943 ms, 中位数 1.741 ms | 4.628-7.226 ms, 中位数 5.141 ms* | db 插件约 3.0x |
| total append chain | 3.931-4.505 ms, 中位数 3.986 ms | 4.628-7.226 ms, 中位数 5.141 ms | db 插件约 1.3x |
| verify/integrity | 0.932-1.080 ms, 中位数 1.062 ms | 34.593-46.971 ms, 中位数 35.797 ms | db 插件约 33.7x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这一轮比前一版更进一步：
- db 仍然稳定领先 baseline ingest、index build、单段 `tx` append、单段 `coltx` append 和 verify；
- empty unsafe bootstrap 现在把 `meta`、`schema`、dict artifact 都延迟到第一次真实持久化写入，同时在那之前仍然能从 cache 正确完成 dict lookup；
- 把 `tx + coltx` 两段合并成 ERP 整条 append 链路后，db 的中位数已经进一步压到 `3.986 ms`，继续领先 SQLite 的 `5.141 ms`；
- init 中位数这次仍然没有领先 SQLite，而且 db 侧样本波动比 SQLite 更大，说明初始化固定成本还需要继续压，当前还不能宣称全面领先。

2026-06-27 同日晚些时候，继续把 unsafe 空表首写路径再压了一轮：
- `internStringDictMany()` 在 `skipDurabilitySync()` 且空表 bootstrap 时，直接原地更新 `unsafe_init_meta_cache`，不再走“拷出一份 `TableMeta` -> 修改 -> 再整份拷回 cache”的往返；
- `acquireTableWriteLock()` 在 unsafe / `:memory:` 路径下只保留进程内锁，不再额外落 `.write.lock` 文件；
- `:memory:name` 重新修正为真正按 name 分桶的共享内存 root，同时保留当前精确 `:memory:` 的 thread-local unnamed root 行为；
- 新增回归测试覆盖：unsafe dict bootstrap 多批次不落盘、unsafe 写路径不生成 lock 文件、named memory root 共享与 exact memory root 本地隔离。

随后再次顺序重跑 5 次 db 和 5 次 SQLite indexed ERP append benchmark。两侧正确性输出仍一致：`8448 / 33792 / 8448`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 1.347-1.651 ms, 中位数 1.380 ms | 0.836-1.100 ms, 中位数 1.007 ms | SQLite |
| baseline ingest before indexes | 4.663-5.785 ms, 中位数 5.497 ms | 63.965-84.495 ms, 中位数 73.188 ms | db 插件约 13.3x |
| build baseline indexes | 8.756-10.066 ms, 中位数 9.881 ms | 18.993-31.826 ms, 中位数 23.711 ms | db 插件约 2.4x |
| append with tx + incremental indexes | 2.089-3.425 ms, 中位数 2.632 ms | 3.860-10.414 ms, 中位数 4.180 ms* | db 插件约 1.6x |
| append with coltx + incremental indexes | 1.610-2.209 ms, 中位数 1.817 ms | 3.860-10.414 ms, 中位数 4.180 ms* | db 插件约 2.3x |
| total append chain | 3.956-5.634 ms, 中位数 4.399 ms | 3.860-10.414 ms, 中位数 4.180 ms | SQLite |
| verify/integrity | 0.903-1.469 ms, 中位数 1.069 ms | 33.110-42.917 ms, 中位数 40.774 ms | db 插件约 38.1x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这一组新样本说明两件事：
- 空表 bootstrap 的字典首写常数成本又降了一截，`db_erp_indexed_init_dict_ns` 已压到 `0.353-0.499 ms`；
- 但在“整条 append chain = tx append + coltx append”这个口径下，这一组 5-run 中位数里 SQLite 回到了 `4.180 ms`，略快于 db 的 `4.399 ms`。因此当前仍然不能宣称“全部领先”。

2026-06-27 最后一轮提交前，又把 unsafe 空表 bootstrap 扩到直接的无索引 blob store 首写路径，并移除了 `deleteTableArtifactsFast()` 在 not-found 路径上的第二次 recovered-meta 扫描。新增回归测试覆盖：blob 首写不落盘但可读、后续真实持久化写会 materialize pending blob、连续 blob bootstrap 只持久化最新 epoch。

随后基于最终提交代码重新 `zig build`，再顺序跑 5 次 db 和 5 次 SQLite indexed ERP append benchmark。两侧正确性输出仍一致：`8448 / 33792 / 8448`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 1.498-2.040 ms, 中位数 1.624 ms | 0.886-1.272 ms, 中位数 0.969 ms | SQLite |
| baseline ingest before indexes | 5.158-5.867 ms, 中位数 5.316 ms | 65.976-99.599 ms, 中位数 67.145 ms | db 插件约 12.6x |
| build baseline indexes | 9.281-11.353 ms, 中位数 10.167 ms | 19.654-22.335 ms, 中位数 21.119 ms | db 插件约 2.1x |
| append with tx + incremental indexes | 2.344-3.480 ms, 中位数 2.806 ms | 4.046-6.188 ms, 中位数 4.487 ms* | db 插件约 1.6x |
| append with coltx + incremental indexes | 1.635-2.043 ms, 中位数 1.887 ms | 4.046-6.188 ms, 中位数 4.487 ms* | db 插件约 2.4x |
| total append chain | 4.005-5.524 ms, 中位数 4.441 ms | 4.046-6.188 ms, 中位数 4.487 ms | db 插件微弱领先，基本持平 |
| verify/integrity | 1.047-1.315 ms, 中位数 1.256 ms | 33.154-39.109 ms, 中位数 36.584 ms | db 插件约 29.1x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这轮不能作为“全部领先”的依据：db 在 baseline、build、单段 append、verify 继续领先，total append chain 中位数也略快，但区间和 SQLite 重叠；init 中位数仍明显慢于 SQLite。blob 首写 bootstrap 是功能覆盖和空表首写路径一致性收益，不是当前 indexed ERP init benchmark 的直接收益，因为这组 init 只包含 remove、schema init 和 dict init。

同日继续压 `removeTable()` 在 unsafe / 空 root 下的固定成本：not-found 路径不再先让 `loadActiveMeta()` 做 recovered-meta 目录扫描、再由 `deleteRootTableArtifacts()` 为 stale artifact cleanup 再扫一次目录；现在合并成一次 root 遍历，同时保留 stale artifact 删除和 `.write.lock` 保留语义。新增回归测试覆盖 unsafe not-found remove 清理 stale 文件且保留 lock 文件。

重新 `zig build` 后顺序跑 5 次 db 和 5 次 SQLite indexed ERP append benchmark。两侧正确性输出仍一致：`8448 / 33792 / 8448`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 1.407-1.569 ms, 中位数 1.507 ms | 0.840-1.348 ms, 中位数 0.966 ms | SQLite |
| init remove component | 0.342-0.547 ms, 中位数 0.366 ms | n/a | db 内部改善 |
| baseline ingest before indexes | 4.911-5.519 ms, 中位数 5.212 ms | 59.753-75.525 ms, 中位数 70.698 ms | db 插件约 13.6x |
| build baseline indexes | 8.573-10.291 ms, 中位数 9.611 ms | 19.998-24.267 ms, 中位数 21.246 ms | db 插件约 2.2x |
| append with tx + incremental indexes | 2.573-3.115 ms, 中位数 2.577 ms | 4.474-9.344 ms, 中位数 5.059 ms* | db 插件约 2.0x |
| append with coltx + incremental indexes | 1.675-1.892 ms, 中位数 1.742 ms | 4.474-9.344 ms, 中位数 5.059 ms* | db 插件约 2.9x |
| total append chain | 4.309-4.790 ms, 中位数 4.469 ms | 4.474-9.344 ms, 中位数 5.059 ms | db 插件约 1.1x |
| verify/integrity | 1.001-1.328 ms, 中位数 1.113 ms | 33.446-39.843 ms, 中位数 36.915 ms | db 插件约 33.2x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这轮证明 remove 固定成本继续下降，尤其 `db_erp_indexed_init_remove_ns` 中位数压到 `0.366 ms`；但总 init 仍是 `1.507 ms` 对 SQLite `0.966 ms`，所以目标“init 稳定领先”仍未达成。

随后继续把 unsafe 空表 bootstrap 的 `schema_path` 也延迟：init cache 中先保留空 `schema_path` / `schema_hash`，直到第一次真实持久化写入 materialize schema/meta 时再补实际 schema path 和 hash。这样少了一段每表 init 期间的路径拼接和分配，同时新增断言覆盖 bootstrap meta 为空 path、持久化后恢复为真实 `.sadb-schema` basename。

重新 `zig build` 后顺序跑 5 次 db 和 5 次 SQLite indexed ERP append benchmark。两侧正确性输出仍一致：`8448 / 33792 / 8448`。这轮 SQLite 的非 init 阶段有明显系统噪声尖峰，但 init 对照仍显示 db 未领先。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 1.322-1.968 ms, 中位数 1.424 ms | 1.028-1.313 ms, 中位数 1.052 ms | SQLite |
| init remove component | 0.349-0.585 ms, 中位数 0.400 ms | n/a | db 内部仍低于旧样本 |
| init schema component | 0.955-1.335 ms, 中位数 1.002 ms | n/a | db 内部改善 |
| baseline ingest before indexes | 4.968-6.312 ms, 中位数 6.065 ms | 77.038-145.649 ms, 中位数 101.117 ms | db 插件约 16.7x |
| build baseline indexes | 9.368-10.980 ms, 中位数 9.484 ms | 24.123-101.663 ms, 中位数 30.403 ms | db 插件约 3.2x |
| append with tx + incremental indexes | 2.302-2.851 ms, 中位数 2.718 ms | 3.972-89.651 ms, 中位数 6.474 ms* | db 插件约 2.4x |
| append with coltx + incremental indexes | 1.787-2.154 ms, 中位数 2.096 ms | 3.972-89.651 ms, 中位数 6.474 ms* | db 插件约 3.1x |
| total append chain | 4.184-4.872 ms, 中位数 4.846 ms | 3.972-89.651 ms, 中位数 6.474 ms | db 插件约 1.3x |
| verify/integrity | 1.076-1.338 ms, 中位数 1.203 ms | 36.269-119.048 ms, 中位数 46.887 ms | db 插件约 39.0x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这轮把总 init 中位数继续压到 `1.424 ms`，schema component 中位数为 `1.002 ms`；但 SQLite init 中位数仍为 `1.052 ms`，db 还没有达到“init 稳定领先”。下一步应继续压 schema parser / column meta 构建固定成本，而不是扩大接口表面。

随后继续压 `compileInitFast()` 的 fixed cost：常见小 schema 的 duplicate-def 检查不再立刻创建 heap `StringHashMap`，而是先走固定容量 inline hash set；超过容量时再 fallback 到 `StringHashMap`。这保持哈希查重，不退化成线性 duplicate scan。新增回归测试覆盖 init-fast duplicate rejection，以及超过 inline 容量后的 fallback duplicate rejection。

重新 `zig build` 后顺序跑 5 次 db 和 5 次 SQLite indexed ERP append benchmark。两侧正确性输出仍一致：`8448 / 33792 / 8448`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 1.290-1.478 ms, 中位数 1.379 ms | 0.875-1.095 ms, 中位数 0.968 ms | SQLite |
| init remove component | 0.309-0.480 ms, 中位数 0.441 ms | n/a | db 内部仍低于旧样本 |
| init schema component | 0.945-0.986 ms, 中位数 0.968 ms | n/a | db 内部改善 |
| baseline ingest before indexes | 4.611-5.287 ms, 中位数 4.964 ms | 57.738-69.982 ms, 中位数 63.373 ms | db 插件约 12.8x |
| build baseline indexes | 8.667-9.300 ms, 中位数 8.825 ms | 19.711-21.575 ms, 中位数 20.691 ms | db 插件约 2.3x |
| append with tx + incremental indexes | 2.133-2.613 ms, 中位数 2.397 ms | 4.297-4.731 ms, 中位数 4.406 ms* | db 插件约 1.8x |
| append with coltx + incremental indexes | 1.589-1.821 ms, 中位数 1.819 ms | 4.297-4.731 ms, 中位数 4.406 ms* | db 插件约 2.4x |
| total append chain | 3.722-4.432 ms, 中位数 4.216 ms | 4.297-4.731 ms, 中位数 4.406 ms | db 插件约 1.0x |
| verify/integrity | 0.935-1.385 ms, 中位数 1.071 ms | 33.348-39.911 ms, 中位数 33.788 ms | db 插件约 31.5x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这轮 schema component 中位数继续降到 `0.968 ms`，但 db 总 init 中位数仍是 `1.379 ms`，SQLite init 中位数是 `0.968 ms`。init 目标还没完成。

同日转入下一项 memory mode 稳定性：memory root 的 read snapshot 不再直接引用全局 `mem://` map 中的 artifact bytes，而是在打开 snapshot 时复制一份由 snapshot 自己释放的 bytes。这样 `:memory:name` 或精确 `:memory:` 里删除、重建、复用同名表时，旧 read handle 仍保持打开时的行数据。随后继续修正 memory snapshot cleanup 的路径匹配：删除表 `foo` 的 snapshot 目录时只删除精确路径或 `/` 子路径，不会误删 `foo_extra` 这类前缀邻居表的 snapshot artifact。再往后，missing-table remove 在 memory root 下也改为纯内存处理，不再进入磁盘 recovered-meta / root artifact 扫描，也不会探测或创建真实 `:memory:*` 目录。之后 memory recover 也切到当前 in-memory active meta 的直接校验和重新发布路径，不再对 `:memory:name` 做真实目录遍历；missing recover 返回 `NotFound`，同样不触碰文件系统。lock、unlock、compact 生命周期也补了 memory root 回归，覆盖 locked 状态拒写、unlock 后校验、compact 合并内存 segment 以及无真实目录副作用。空表 bootstrap 随后继续扩到“先建索引、后首写”的路径：unsafe 空表创建空索引时只更新缓存 metadata，不写空 index artifact 或 meta 文件，首个 indexed write 再 materialize 真实 index 文件并保持唯一约束。接口侧也同步了 `benchmark_test/db.sai` 和 `benchmark_test/db.sal`，恢复 `DB_TX_INSERT_ROWS` 的测试副本声明和宏，并让 `db_tx_smoke.sa` 实际通过公开宏批量插入两行后用 read handle 校验结果。新增回归测试覆盖 memory read snapshot 在 remove + reuse 后仍读到旧行、新 snapshot 读到新行，前缀邻居表 snapshot 互不影响，missing remove 不触碰文件系统，memory recover active 表不创建目录，missing recover 不触碰文件系统，memory lock/unlock/compact 全程留在内存里，以及 unsafe empty-index bootstrap 延迟到第一批真实行写入。这是内存模式隔离语义、空表自举和接口同步修正，不更新 indexed ERP vs SQLite 性能表。

随后基于延迟空索引 bootstrap artifact 的代码重新 `zig build`，再顺序跑 5 次 db 和 5 次 SQLite indexed ERP append benchmark。两侧正确性输出仍一致：`8448 / 33792 / 8448`。这轮衡量的是“先建空索引、首批真实 indexed write 再 materialize index 文件”的固定成本影响；db init 继续小幅改善，但 SQLite init 仍领先。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 1.246-1.647 ms, 中位数 1.345 ms | 0.732-0.905 ms, 中位数 0.824 ms | SQLite |
| init remove component | 0.325-0.614 ms, 中位数 0.431 ms | n/a | db 内部仍低于旧样本 |
| init schema component | 0.855-1.153 ms, 中位数 0.916 ms | n/a | db 内部改善 |
| baseline ingest before indexes | 4.721-5.411 ms, 中位数 5.211 ms | 60.221-77.626 ms, 中位数 69.391 ms | db 插件约 13.3x |
| build baseline indexes | 8.457-9.419 ms, 中位数 8.912 ms | 19.933-31.352 ms, 中位数 21.009 ms | db 插件约 2.4x |
| append with tx + incremental indexes | 2.085-2.799 ms, 中位数 2.338 ms | 4.036-5.053 ms, 中位数 4.638 ms* | db 插件约 2.0x |
| append with coltx + incremental indexes | 1.523-1.912 ms, 中位数 1.553 ms | 4.036-5.053 ms, 中位数 4.638 ms* | db 插件约 3.0x |
| total append chain | 3.697-4.711 ms, 中位数 3.862 ms | 4.036-5.053 ms, 中位数 4.638 ms | db 插件约 1.2x |
| verify/integrity | 0.919-1.073 ms, 中位数 0.961 ms | 34.095-38.241 ms, 中位数 36.382 ms | db 插件约 37.9x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这轮 schema component 中位数从前一组 `0.968 ms` 降到 `0.916 ms`，总 init 中位数从 `1.379 ms` 降到 `1.345 ms`。不过 SQLite init 中位数这轮是 `0.824 ms`，所以仍不能声明“全部领先”。当前可确认的是：db 在 baseline ingest、build indexes、tx append、coltx append、total append chain、verify/integrity 的中位数均领先；init 仍是下一轮优化目标。

随后继续收窄 missing-table remove 的固定成本：unsafe 模式下，如果非 memory root 目录本身不存在，`removeTable` 现在直接跳过 compat meta 探测、recovered-meta 目录扫描、stale artifact 扫描和 snapshot tree 删除，同时仍清理同进程 unsafe bootstrap cache。这个路径是 O(1)，并保留已有 root 存在时的 stale artifact cleanup / lock preservation 行为。新增回归测试覆盖 missing root 不被创建、bootstrap cache 被 remove 清掉、之后 `loadActiveMeta` 返回 `NotFound`。

重新 `zig build` 后顺序跑 5 次 db 和 5 次 SQLite indexed ERP append benchmark。两侧正确性输出仍一致：`8448 / 33792 / 8448`。这轮 `init_remove` 分量下降，但 schema/dict 分量有波动，总 init 中位数仍落后 SQLite。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 1.322-1.637 ms, 中位数 1.489 ms | 0.940-1.609 ms, 中位数 1.129 ms | SQLite |
| init remove component | 0.327-0.501 ms, 中位数 0.396 ms | n/a | db 内部改善 |
| init schema component | 0.865-1.158 ms, 中位数 0.986 ms | n/a | db 内部波动 |
| baseline ingest before indexes | 5.110-6.367 ms, 中位数 5.196 ms | 62.266-105.283 ms, 中位数 78.473 ms | db 插件约 15.1x |
| build baseline indexes | 8.822-11.155 ms, 中位数 9.841 ms | 22.414-27.335 ms, 中位数 22.813 ms | db 插件约 2.3x |
| append with tx + incremental indexes | 2.320-2.611 ms, 中位数 2.560 ms | 4.659-7.260 ms, 中位数 5.023 ms* | db 插件约 2.0x |
| append with coltx + incremental indexes | 1.833-2.100 ms, 中位数 1.895 ms | 4.659-7.260 ms, 中位数 5.023 ms* | db 插件约 2.7x |
| total append chain | 4.156-4.660 ms, 中位数 4.443 ms | 4.659-7.260 ms, 中位数 5.023 ms | db 插件约 1.1x |
| verify/integrity | 0.971-1.123 ms, 中位数 1.062 ms | 34.858-51.751 ms, 中位数 38.965 ms | db 插件约 36.7x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这轮只能证明 missing-root remove fast path 的局部分量收益：`db_erp_indexed_init_remove_ns` 中位数从上一组 `0.431 ms` 到 `0.396 ms`。总 init 这轮为 db `1.489 ms` 对 SQLite `1.129 ms`，所以仍不能声明“全部领先”。下一步继续压 schema/dict init 固定成本，而不是扩大接口表面。

随后压 `sa_db_dict_intern_many` 的小批量 ABI 入口：8 项以内的 values / inserted 临时数组改用栈上 inline buffer，超过容量仍回退到 arena 分配。ERP indexed init 的两个状态字典批次都是 2 项，正好命中这条路径；接口语义和大批量行为不变。先跑一组 db 5-run 出现明显系统噪声，随后用第二组稳定 db 5-run 和同轮 SQLite 5-run 记录如下。两侧正确性输出仍一致：`8448 / 33792 / 8448`。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 1.360-1.884 ms, 中位数 1.517 ms | 0.920-1.110 ms, 中位数 0.949 ms | SQLite |
| init remove component | 0.334-0.498 ms, 中位数 0.422 ms | n/a | db 内部波动 |
| init schema component | 0.935-1.351 ms, 中位数 1.064 ms | n/a | db 内部波动 |
| init dict component | 0.383-0.522 ms, 中位数 0.445 ms | n/a | db 内部改善 |
| baseline ingest before indexes | 4.630-5.585 ms, 中位数 5.555 ms | 65.730-82.277 ms, 中位数 67.873 ms | db 插件约 12.2x |
| build baseline indexes | 8.175-10.536 ms, 中位数 9.121 ms | 23.561-27.322 ms, 中位数 24.881 ms | db 插件约 2.7x |
| append with tx + incremental indexes | 2.165-2.716 ms, 中位数 2.285 ms | 4.051-5.433 ms, 中位数 4.983 ms* | db 插件约 2.2x |
| append with coltx + incremental indexes | 1.683-2.459 ms, 中位数 2.146 ms | 4.051-5.433 ms, 中位数 4.983 ms* | db 插件约 2.3x |
| total append chain | 3.847-5.175 ms, 中位数 4.432 ms | 4.051-5.433 ms, 中位数 4.983 ms | db 插件约 1.1x |
| verify/integrity | 0.937-1.949 ms, 中位数 1.192 ms | 34.751-41.753 ms, 中位数 38.336 ms | db 插件约 32.2x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这轮只作为 dict init 固定成本的小幅收益记录：`db_erp_indexed_init_dict_ns` 中位数从上一组稳定样本约 `0.462 ms` 降到 `0.445 ms`。总 init 仍是 db `1.517 ms` 对 SQLite `0.949 ms`，schema/remove 波动仍然主导初始化差距。

随后确认前面多轮 benchmark 使用的 SA runtime 里安装过旧 `libdb.so`，而不是刚刚 `zig build` 出来的当前插件。重新安装当前开发插件后再跑同一组 5 次 db / 5 次 SQLite indexed ERP append benchmark：

```bash
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_db
```

两侧正确性输出仍一致：`8448 / 33792 / 8448`。这轮是当前代码和当前已安装插件一致时的有效对比样本；之后重跑 SA benchmark 前必须先更新安装插件，否则会测到旧实现。

2026-06-27 继续把 unsafe init template cache 扩到 schema-source 路径：重复同一 schema 的 init/remove/reinit 现在先用 `schema_path_hint + schema_source` 的快速指纹做固定槽位缓存查询，并且命中后仍精确比较 schema source，避免碰撞误复用。新增回归测试覆盖 v1 schema 命中、v2 schema 不误命中，以及 remove/reinit 后列布局正确。这项收益主要作用于同进程重复初始化同一 schema 的路径；下面 ERP 三表 benchmark 每个 schema 只 init 一次，因此作为端到端无回归和 SQLite 当前对照样本，而不是把该 cache 归因到 one-shot schema component。

随后继续扩展空表首写自举：空表先创建 blob eq 索引、再调用 `putBlobValue()` 时，不再因为存在 blob index 就提前 materialize meta/blob/index artifact；只要表仍是 row_count=0 且没有 segment，就继续保留在 unsafe bootstrap cache。首个真实行写入会用 pending blob bytes 构建并落地 blob index。新增回归测试覆盖 meta/blob/index 均延迟到第一行写入、之后可通过唯一 blob eq key 读取整行并通过 verify。这是首写入口覆盖扩展，不单独更新下面的 ERP 5-run 性能表。

| 操作 | db 插件 | SQLite | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 0.166-0.226 ms, 中位数 0.217 ms | 1.033-3.603 ms, 中位数 1.583 ms | db 插件约 7.3x |
| init remove component | 0.218-0.259 ms, 中位数 0.239 ms | n/a | db 内部分量 |
| init schema component | 0.094-0.153 ms, 中位数 0.114 ms | n/a | db 内部分量 |
| init dict component | 0.058-0.067 ms, 中位数 0.060 ms | n/a | db 内部分量 |
| baseline ingest before indexes | 4.745-5.716 ms, 中位数 5.159 ms | 94.176-115.508 ms, 中位数 100.015 ms | db 插件约 19.4x |
| build baseline indexes | 9.375-11.896 ms, 中位数 9.576 ms | 25.721-35.446 ms, 中位数 32.151 ms | db 插件约 3.4x |
| append with tx + incremental indexes | 2.258-2.852 ms, 中位数 2.513 ms | 5.800-11.919 ms, 中位数 6.674 ms* | db 插件约 2.7x |
| append with coltx + incremental indexes | 1.768-2.134 ms, 中位数 2.003 ms | 5.800-11.919 ms, 中位数 6.674 ms* | db 插件约 3.3x |
| total append chain | 4.198-4.882 ms, 中位数 4.441 ms | 5.800-11.919 ms, 中位数 6.674 ms | db 插件约 1.5x |
| verify/integrity | 0.950-2.983 ms, 中位数 1.203 ms | 43.697-51.121 ms, 中位数 44.948 ms | db 插件约 37.4x |

`*` SQLite 对照这里只有一条追加路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这轮改变 indexed ERP write benchmark 的当前结论：在已安装插件和源码一致后，db 插件已经在该 benchmark 的 init、baseline ingest、index build、`tx` append、`coltx` append、total append chain、verify/integrity 中位数上全部领先 SQLite。这个结论只覆盖这组 unsafe/no-sync indexed ERP 写入 benchmark，不等价于 SQL 功能、ACID/WAL、崩溃恢复、compact/vacuum 或通用运维能力全面超过 SQLite。

随后进入真正的内存模式目标：新增 `db_erp_indexed_memory_bench.sa`，用 named root `:memory:erp_indexed` 跑同一组三表 indexed ERP write workload；同时新增 `sqlite_erp_indexed_memory_bench.sa`，用 SQLite `:memory:` 作为对照。第一轮完整 memory benchmark 已确认功能覆盖真实 workload：init、dict、baseline ingest、批量建索引、`tx` append、`coltx` append、verify 全部跑通，且 db 侧不创建真实 `:memory:` 或 `:memory:erp_indexed` 目录。

这轮实现继续把 memory root 纳入 unsafe/no-sync indexed append fast path：`mem://` index artifact 的 merge/append 不再被排除在增量索引 in-place 路径之外；随后把 memory index artifact 和 segment column artifact 的扩容改为优先 allocator `remap`，只写新增尾部，避免默认 `alloc + copy old + copy appended`。新增回归测试覆盖 `:memory:` root 在 unsafe fast path 下追加唯一单列索引和唯一 pair 索引，verify/query 正确且没有真实目录副作用。

最终同轮 5 次 db memory / 5 次 SQLite `:memory:` indexed ERP append benchmark 如下。两侧正确性输出仍一致：`8448 / 33792 / 8448`。

| 操作 | db `:memory:` 插件 | SQLite `:memory:` | 最快 |
| --- | ---: | ---: | --- |
| init indexed ERP tables | 0.158-0.186 ms, 中位数 0.161 ms | 0.498-0.650 ms, 中位数 0.628 ms | db 插件约 3.9x |
| init remove component | 0.183-0.228 ms, 中位数 0.199 ms | n/a | db 内部分量 |
| init schema component | 0.097-0.120 ms, 中位数 0.099 ms | n/a | db 内部分量 |
| init dict component | 0.056-0.063 ms, 中位数 0.058 ms | n/a | db 内部分量 |
| baseline ingest before indexes | 2.659-3.172 ms, 中位数 2.888 ms | 71.975-92.521 ms, 中位数 84.496 ms | db 插件约 29.3x |
| build baseline indexes | 7.360-9.020 ms, 中位数 8.074 ms | 22.431-26.772 ms, 中位数 23.628 ms | db 插件约 2.9x |
| append with tx + incremental indexes | 1.331-1.919 ms, 中位数 1.421 ms | 3.879-4.871 ms, 中位数 3.936 ms* | db 插件约 2.8x |
| append with coltx + incremental indexes | 0.945-1.352 ms, 中位数 1.105 ms | 3.879-4.871 ms, 中位数 3.936 ms* | db 插件约 3.6x |
| total append chain | 2.276-3.271 ms, 中位数 2.705 ms | 3.879-4.871 ms, 中位数 3.936 ms | db 插件约 1.5x |
| verify/integrity | 0.271-0.456 ms, 中位数 0.394 ms | 36.099-54.805 ms, 中位数 41.082 ms | db 插件约 104.3x |

`*` SQLite `:memory:` 对照这里只有一条追加事务路径，没有再单拆出 `coltx` 形态，所以同一组 SQLite append 样本同时对照 db 的 `tx` 与 `coltx` 子路径。

这轮 memory benchmark 的当前结论：对于这组 unsafe/no-sync indexed ERP 写入工作负载，db 的 named `:memory:` 模式已经在 init、baseline ingest、index build、`tx` append、`coltx` append、total append chain、verify/integrity 中位数上全部领先 SQLite `:memory:`。这不是 SQL 功能或持久化 ACID/WAL 能力的等价声明，但说明内存模式已经不只是 smoke 覆盖，而是可承载完整 ERP 类型、索引和事务路径。

随后补充公开接口层 exact memory smoke：新增 `db_memory_exact_smoke.sa`，使用精确 root `:memory:` 通过 `db.sal` 宏完成 remove/init、唯一 `u64` index、事务插入、read-handle find/get、verify；再用同名表验证 named root `:memory:sa_exact_peer` 初始打开返回 `SA_DB_ERR_NOT_FOUND`，写入不同值后不会污染 exact `:memory:` 的重新打开结果。这条 smoke 证明 SQLite 常见的精确 `:memory:` 入口已经从公开 `.sal` 层可用，并和 named memory root 隔离。实际验证命令：

```bash
sa build-exe benchmark_test/db_memory_exact_smoke.sa -o benchmark_test/db_memory_exact_smoke.out --no-incremental
./benchmark_test/db_memory_exact_smoke.out
```

该补充是接口覆盖和隔离语义证据，不改变上面的 indexed ERP memory 性能表。

## 结论

- 查询速度：复用 read-handle 的 100 次全表 SUM，db 插件在串行和并发查询下都快于 SQLite。
- 并发 benchmark 现在各自跑在独立 root 下，历史工件和 SQLite WAL/SHM 侧文件不再污染结果。
- 读句柄打开不再被全局 mutation 锁阻塞；活跃写事务期间也能打开已提交快照读取。
- 并发插入：在当前 3-run 隔离样本里，原始 `sa_db_ingest_columns` 和新的 `sa_db_coltx_*` 批量列 session 都快于 SQLite，其中 `coltx` 最快。
- 新增的 ABI 修复把 `sa_db_coltx_add_columns` 从“持有全局 handle mutex 执行整段 staging I/O”改成了带引用计数的共享获取，直接改善了多 session 并发追加。
- 批量写入和全量列更新：db 插件更快，主要受益于列式 raw column ingest。
- 当前 indexed ERP write benchmark 在安装当前开发插件后，db 插件的 init、建索引、append 链路和 verify/integrity 中位数都领先 SQLite；旧 ERP workflow 和非 indexed 写入历史样本仍按各自表格解释。
- 当前 indexed ERP memory benchmark 中，named `:memory:` db root 对 SQLite `:memory:` 也在 init、建索引、append 链路和 verify/integrity 中位数上全部领先。
- SQLite 在通用 SQL、ACID/WAL、崩溃恢复、compact/vacuum、成熟运维工具和广泛兼容性上仍更完整。
- 带二级索引的 ERP append-only 写入现在已经走增量索引维护，db 不再为这条路径付出整表 `rebuildIndexes()` 的成本；相对旧 ERP workflow 里的全量建索引阶段，db 侧建索引成本已经明显下降。
- 之前出现的并发失败，主要是 benchmark 工件共享导致的污染，不是当前这轮隔离结果里的稳定行为。

综合回答“哪个最快”：当前这轮 benchmark 里，串行查询、并发查询、原始并发插入、`coltx` 并发插入，都是 db 更快；其中并发插入最快的是 `coltx`。但这组并发插入仍然是无显式二级索引的 workload，带主键/二级索引的 ERP 写入对照还需要单独补基准。
