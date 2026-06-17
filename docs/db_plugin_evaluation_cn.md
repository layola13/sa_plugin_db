# sa_plugin_db 使命、完成度与改进评估

> **评估日期**：2026-06-15
> **评估范围**：`sa_plugin_db` 0.1.0 当前主线
> **依据**：`sap.json` / `db.sai`（285 个 extern 符号）/ `db.sal`（315 处宏与常量）/ `src/` 约 33K 行 Zig 实现 / `progress.md` / `README.md` / `docs/db_plugin_design.md`，并对照 `sci/docs/database.md` 与 `sci/docs/db_comparison.md`（vs SQLite benchmark）
> **立场**：诚实评估，不为完成度漂白；不建议为了对标 SQLite 而背离设计哲学

---

## 1. 使命定位（必须先校准）

### 1.1 上游设计文档（`sci/docs/database.md`）声明的使命

> **`sa-db` 不是 SQL 数据库，是 SA 包管理在数据维度上的同构延伸**：
> - 表 schema = 编译期 `#def` 字典（`.sadb-schema`）
> - 查询 = 预编译 SA-ASM 模块（`.qmod`） + SHA-256 锁版
> - 权限 = 模块级 `grants` 白名单（与包管理同构）
> - 执行 = mmap 只读切片注入到沙箱 + Referee X 光扫描 + 越权 SIGSEGV 物理熔断

**关键拒绝项**（来自 `database.md` 与 `faq.md` D 系列）：
- ❌ SQL 字符串解析（注入风险，运行时开销）
- ❌ B-Tree（用 SoA 列式 + 物理行索引直跳替代）
- ❌ MVCC（与 SoA 顺序写、Bump Arena 冲突）
- ❌ WAL（"零隐式状态"原则禁止后台日志）
- ❌ 中心化 registry / 任何隐式 schema 演进

### 1.2 当前插件实际做了什么

| 维度 | 上游设计 | 当前实现 | 一致度 |
|------|---------|---------|--------|
| Schema 定义 | `.sadb-schema` 编译期 `#def` | ✅ `sa db init` 生成 `.sai` | ✅ |
| 列式存储 | SoA + 段文件 + Arena | ✅ `<tbl>.col<i>.<seg>.dat` | ✅ |
| 预编译查询 (`.qmod`) | SHA-256 注册 + grants | ✅ `sa db register/exec` | ⚠️ 受限的指令形态 |
| 读句柄 (`read handle`) | 上游未明确 | ✅ snapshot 复制只读列 | 新增能力，方向对 |
| 类型键写 / upsert / delete | 上游未明确 | ✅ 整套 `u8..u64 / i8..i64 / pair / blob_eq` | 新增，组合爆炸 |
| 谓词 planner | 上游未明确 | ✅ `u64+i64` / `u64+blob_eq` / `u64+date+decimal_i64` 等硬编码组合 | 新增，**ERP 专用化** |
| 事务（单表） | 上游未提及 | ✅ `tx_begin/tx_*` | 新增 |
| 字典 intern | 上游未提及 | ✅ `tx_dict_intern` | 新增 |
| 冷热分层 (RAM→NVMe→S3) | 设计图明示 | ❌ 未实现 | **未做** |
| Blob Arena 段死亡重写 | 设计图明示 | ❌ 部分实现 | **不完整** |
| Referee X 光扫描 grants | 强制要求 | ✅ register 时校验 | ✅ |
| mmap PROT_READ 越权熔断 | 强制要求 | ⚠️ 文档声明，未见 CI 验证 | **需审计** |
| WAL / crash recovery | 主动拒绝 | ⚠️ 依赖文件系统原子性 | 与设计一致，但**未验证** |

### 1.3 使命漂移现象

**正面**：核心 SoA + grants + predefined query 落地了，方向没跑偏。

**有漂移迹象**：
- 285 个 `sa_db_*` 符号里，约 **120+ 个是 ERP 业务专用 planner**（`u64+i64+bool`、`u64+date+decimal_i64`、`u64+i64+i64`、`u64+i64+blob_eq` 等）。这超出了"通用列存"范畴，看起来是**为某个内部 ERP demo 反向倒推出的 API**。
- 类型键 API 出现 8 × 3 × 2 = 48 种组合（key 类型 × 操作 × tx/非 tx）。**这是 C 模板缺失的典型综合症**，靠人手维护会持续膨胀。
- `db_plugin_design.md` 仍维持"项目本地数据库"叙事，但 progress.md 实际覆盖的是"ERP planner + 字典 intern + blob_eq 业务键"。两份文档的口径不同步。

### 1.4 使命的诚实重述（建议）

把使命语句从"local file-backed column store" 升级为：

> **sa_plugin_db 是 SA 生态的嵌入式列式 OLAP/ERP 引擎**：
> - **数据模型**：固定宽度 SoA 列 + blob arena + 字典 intern + 谓词组合 planner
> - **查询模型**：预编译 `.qmod` + grants 静态权限 + 读句柄复制快照（`O(1)` 命中后无锁扫描）
> - **写模型**：单表事务 + 类型键 upsert/update/delete
> - **不替代**：不是 SQLite / 不是 DuckDB / 不是 PostgreSQL；**不做 SQL，不做 B-Tree，不做 MVCC，不做 WAL**
> - **适用边界**：表 ≤ 数亿行、读多写少、ERP / 报表 / 流水台账场景

这样开发者一眼能判断"该用 / 不该用"。

---

## 2. 完成度评分

### 2.1 按 `progress.md` 已声明 100% 的 16 项原始 feature

| Feature | 评分 | 备注 |
|---------|------|------|
| sap.json 清单与权限 | ✅ 100% | 项目本地 fs + 零 net/env/process |
| 运行时 descriptor / CLI | ✅ 100% | `database` skill |
| `db init` schema | ✅ 100% | 生成 `.sai` |
| `db register` qmod | ✅ 100% | SHA-256 + grants 校验 |
| `db inspect / status` | ✅ 100% | metadata 报告 |
| `db exec` 执行 | ✅ 100% | **限定指令形态**（标量 / 读 / 写 / RMW / atomic cursor） |
| `db ingest` CSV/JSONL | ✅ 100% | 段追加 |
| `db snapshot / restore` | ✅ 100% | 文件复制，**未做 COW，速度比 SQLite 慢 3.6×** |
| `db verify` | ✅ 100% | 哈希校验，**比 SQLite 慢 3.3×** |
| `db compact` | ✅ 100% | 段合并 |
| `db lock / unlock` | ✅ 100% | metadata + 文件 readonly |
| 安装 smoke | ✅ 100% | dev install + verify |
| qmod 集成示例 | ✅ 100% | `docs/qmod_examples.md` |
| 接口策略（导出 sai/sal） | ✅ 100% | `sap.json` 已发布 `db.sai`/`db.sal` |
| qmod 执行表达式扩展 | ✅ 100% | `and/or/xor/shl/lshr` 等 |

**原始 16 项 = 100% 完成，无水分。**

### 2.2 按"列式 OLAP/ERP 引擎"广义使命

| 维度 | 完成度 | 缺口 |
|------|--------|------|
| **列存基础（SoA、段文件、ingest）** | 95% | 缺压缩段、缺增量编码（PFOR / RLE） |
| **谓词 planner** | 70% | 硬编码 4-5 种组合；缺通用 N-way、缺基于统计的 cost model |
| **聚合（SUM / COUNT / MIN / MAX / GROUP BY）** | 75% | SUM/COUNT/GROUP 在，缺 MIN/MAX/AVG/STDDEV/HAVING |
| **JOIN** | 0% | 无任何 join 支持 |
| **二级索引** | 30% | 仅"类型键唯一索引"用于写路径；无通用非唯一索引 |
| **事务（单表）** | 70% | 有 `tx_*` 接口，但缺隔离级别声明 / 跨表事务 |
| **崩溃恢复** | 20% | 依赖文件系统原子 rename；**无显式 fsync 协议、无 epoch 恢复测试** |
| **Blob Arena（按设计应有 mmap bump + 段死亡重写）** | 50% | 基础读写在，**段重写策略未见落地** |
| **冷热分层（RAM→NVMe→S3）** | 0% | 设计图明示但未启动 |
| **Snapshot / 备份** | 60% | 全量复制有，**无增量、无点-in-time recovery** |
| **可观察性** | 30% | 仅 `db inspect`；无 query 统计、无慢查询日志、无容量指标 |
| **并发模型（同进程）** | 80% | 同进程互斥已加；**跨进程文件锁协议未声明** |
| **Schema 演进 / 在线 ALTER** | 0% | 当前路径：`remove_table` + 重 ingest |
| **类型系统覆盖** | 60% | 固定宽度 + blob_eq + decimal_i64 + date / timestamp；缺 ARRAY / JSON / UUID / nullable |
| **错误模型** | 70% | `SaDbErr*` 状态码到位；缺细粒度 reason payload |

**广义完成度估计：约 55-60%**。原始使命已收尾，扩展使命正在做。

---

## 3. 主要问题诊断

### 3.1 🔴 问题 1：API 表面组合爆炸（最严重）

**现象**：
- 285 个 extern；同一概念（如 "by typed key upsert"）按 `{u8, i8, u16, i16, u32, i32, u64, i64} × {direct, tx} × {upsert, update, delete}` = **48 个变体**
- planner 也按 `{u64+i64, u64+u64, i64+i64, u64+blob_eq, i64+blob_eq, u64+i64+blob_eq, u64+i64+bool, u64+i64+i64, u64+date+decimal_i64}` 暴增

**根因**：C-ABI 无泛型。Zig 端在用 `comptime` 生成函数，但 SA 侧每个变体都要手写 `.sai` 声明 + `.sal` 宏 facade。

**影响**：
- ABI 表面增长 = 文档维护成本 + LLM 学习成本 + 测试矩阵爆炸
- 每加一种类型组合，要改 ~4 个文件（zig / sai / sal / smoke）
- LLM Agent 容易选错变体（"我要 i64 key + bool 谓词…哦没有，那 u64 + bool 行不行？"）

**改进方向（按 ROI）**：
1. **统一 `key_type: u8 enum` 派遣入口**：把 48 个键写函数收敛成 6 个（upsert/update/delete × direct/tx），第 1 个参数显式带 `KeyType` enum。SA 侧 macro 仍可分类型 facade，但 native 实现合并。
2. **planner 改通用谓词树**：用 `SaDbPredicate { kind: u8, col_index: u32, value_lo: u64, value_hi: u64 }[]` 数组 + 一个通用 `sa_db_plan` 入口；不同业务组合通过传不同谓词数组实现。砍掉硬编码的 4-5 种 ERP 排列组合。
3. **`.sal` facade 保留**（开发者侧仍按业务习惯调用），**但 native ABI 必须先收敛**。

**预期收益**：285 → 估计 80-100 个 extern；文档 / 测试 / Agent 学习成本下降 60%+。

**工程量**：3-4 周（机械重构 + 等价性测试）。

**风险**：当前所有 demo / smoke / `benchmark_test` 都依赖 fat ABI；必须有兼容层过渡。

---

### 3.2 🔴 问题 2：崩溃恢复未验证

**现状**：
- 设计文档说"不用 WAL，靠快照 epoch + 不可变段 + 原子游标"
- 代码层面：mmap + sequential append + `atomic_rmw_add global_len, 1` 串行化
- **但 progress.md 没有任何"power loss test / kill -9 mid-tx / disk full mid-ingest"的验证记录**

**风险场景**：
| 故障 | 当前行为（推测） | 应有行为 |
|------|----------------|---------|
| 写一半 SIGKILL | 部分段写入；`global_len` 未更新 → 数据丢但元数据一致 | 同 |
| disk full mid-ingest | `write()` 返回短写；段文件损坏 | 应原子拒绝并回滚到上一 epoch |
| disk full mid-tx commit | tx 日志损坏（如果有的话） | 启动时回滚到 tx_begin 前 |
| `global_len` 自增但段写入崩溃 | "幽灵行"，读到 garbage | epoch 恢复扫描应丢弃 |
| mmap 页 dirty 但未 fsync 时断电 | OS 决定丢/留 | 应有显式 fsync barrier |

**改进方向**：
1. **写一个崩溃恢复测试套件**：fork + kill -9 + 重启 verify，覆盖 5+ 种故障点
2. **明确 fsync 协议**：哪些写之后必须 fsync？`ingest` 提交段 / `tx commit` / `compact` 完成？
3. **epoch 恢复证明**：启动时如何决定"最后一个一致的 epoch"？测试不一致 epoch 是否能被丢弃
4. **文档化**：在 `db_plugin_design.md` 加 "Durability and Recovery" 一节，说清承诺与边界

**预期收益**：从"看起来安全"升级为"可证明 / 可测试安全"。是 db 类组件的硬基础线。

**工程量**：2-3 周（包括测试 harness）。

---

### 3.3 🟠 问题 3：性能短板未补齐

`db_comparison.md` 已经诚实列出落后项：

| 操作 | db 插件 | SQLite | 落后倍数 | 根因猜测 |
|------|--------:|-------:|---------|---------|
| create/init | 6.7 ms | 0.6 ms | **11.3×** | 目录层级 + metadata JSON 序列化 |
| sum (single scan) | 5.4 / 3.7 ms | 3.3 / 2.8 ms | 1.5× | mmap + 全列扫描，未用 SIMD |
| compact/vacuum | 20.3 ms | 5.6 ms | 3.6× | 段合并 = 全文件复制 |
| verify | 11.6 ms | 3.5 ms | 3.3× | 全段 SHA-256 |

**改进方向**：
1. **init 慢**：metadata 用 binary format 替代 JSON；目录创建延迟到首次 ingest
2. **SUM 慢**：列扫描走 AVX2 / AVX-512（每次 32-64 个 u64 累加）；提前算"前缀和"段元数据避免全扫
3. **compact 慢**：用"段引用计数 + COW"，新段写完旧段引用降为 0 才删除
4. **verify 慢**：blake3 替代 SHA-256（吞吐 5-10×）；或缓存段哈希避免重算

**预期收益**：3 项操作综合提升 2-5×；让 db 插件在所有 benchmark 维度都不输 SQLite。

**工程量**：每项 1-2 周，可独立推进。

---

### 3.4 🟠 问题 4：JOIN 完全缺失

**现状**：所有"多表查询"目前必须靠应用层 SA 代码自己 fetch + nest loop join。

**根因**：上游设计文档没有提到 join，因为它聚焦在"单表预编译查询 + grants"。但 ERP 场景**不可能没有 join**（订单-客户、订单-行项目）。

**改进路径（按 ROI）**：
1. **最朴素**：暴露 `sa_db_open_read_handle_dual(&tbl_a, &tbl_b, ...)` + `sa_db_join_inner_hash_u64_u64(...)`。
   - 只支持等值 join + 整数键
   - inner / left outer 两种
   - hash 表用 sa_std HashMap
2. **planner 集成**：扩展 `SaDbPlan3Info` 到 `SaDbJoinPlan`，让 planner 能选择 join 顺序
3. **流式 join**：返回 cursor 而非全量行集，避免大表 OOM

**预期收益**：ERP 场景实用度跨数量级提升。

**工程量**：4-6 周（核心 hash join + planner + 测试）。

---

### 3.5 🟠 问题 5：观察性几乎为零

**现状**：仅 `db inspect`，看不到：
- 每个 read handle 的命中率 / 扫描行数
- qmod 执行的 cycle 数 / instruction count
- 段大小 / 段年龄 / 段死亡率
- 当前活跃 tx 数

**改进方向**：
1. `sa_db_stats(table, &out: ptr) -> u32` 暴露 metric struct
2. `sa db top` / `sa db slow-queries` CLI 子命令
3. JSON 输出格式与 agent-first toolchain 对齐
4. Prometheus / OpenTelemetry 是过度设计，**不要做**

**工程量**：1-2 周。

---

### 3.6 🟡 问题 6：类型系统不完整

**当前支持**：固定宽度整数 + f32/f64 + decimal_i64 + date + timestamp_ms/us + blob_eq + bool

**缺失（按重要性排）**：
1. **nullable 列**：有 `null_bitmap_*` API 但**未整合进 planner / 读句柄**
2. **数组列**：ERP 报表常有 "tags: []text"
3. **JSON 列**：与 sa_std JSON 联动
4. **UUID / 长字符串**：现在只能走 blob_eq，无序
5. **复合外键 / 复合唯一索引**：有 `u64_pair_key` 但不通用

**改进方向**：先把 nullable 完整接入（null bitmap 已经有），其他按需求驱动。

**工程量**：nullable 集成 1 周；其他视优先级。

---

### 3.7 🟡 问题 7：Schema 演进 = 推倒重来

**现状**：要改 schema 必须 `remove_table` + 重新 ingest。生产数据丢失级别的操作。

**改进方向**：
- `sa db migrate <table> --add-column "<name>:<type>"`：在末尾追加列段，旧行的新列填 null
- `sa db migrate <table> --drop-column <name>`：仅 metadata 标记 dropped，段文件不动；下次 compact 物理删除
- `--rename-column` / `--change-type` 谨慎评估

**工程量**：每种迁移操作 ~3-5 天。

---

### 3.8 🟢 问题 8：跨进程并发未声明

**现状**：同进程互斥已加（db_comparison 显式提到）。**跨进程未声明协议**——两个 `sa` CLI 同时 ingest 同表会发生什么？

**改进方向**：
1. 单写者 advisory file lock（`flock` LOCK_EX）
2. 多读者 + 单写者：读用 LOCK_SH、写用 LOCK_EX
3. 锁文件路径：`<root>/<table>.lock`
4. 文档化"sa-db 不是跨主机分布式 DB，仅同主机多进程"

**工程量**：1 周。

---

## 4. 改进路线（推荐顺序）

### 4.1 P0：补齐基础线（不补完不该宣传"稳定"）

| 优先级 | 任务 | 工程量 | 出处 |
|--------|------|--------|------|
| ⭐⭐⭐⭐⭐ | 崩溃恢复测试 + fsync 协议明示 | 2-3 周 | §3.2 |
| ⭐⭐⭐⭐⭐ | ABI 表面收敛（285 → ~80-100） | 3-4 周 | §3.1 |
| ⭐⭐⭐⭐ | 跨进程文件锁协议 | 1 周 | §3.8 |
| ⭐⭐⭐⭐ | 性能短板：init / compact / verify | 2-3 周 | §3.3 |

**完成后可以挂"稳定 0.1.x" 标签。**

### 4.2 P1：扩展使命（ERP / OLAP 实用化）

| 优先级 | 任务 | 工程量 |
|--------|------|--------|
| ⭐⭐⭐⭐ | 整数键 hash JOIN（inner + left outer） | 4-6 周 |
| ⭐⭐⭐ | 通用谓词树 planner（替代硬编码组合） | 3-4 周 |
| ⭐⭐⭐ | 聚合扩展（MIN / MAX / AVG / HAVING） | 2 周 |
| ⭐⭐⭐ | nullable 列接入 planner / 读句柄 | 1 周 |
| ⭐⭐ | Schema 演进（add/drop column） | 2-3 周 |
| ⭐⭐ | 可观察性 metric struct + `db top` | 1-2 周 |

### 4.3 P2：高级能力（与设计文档对齐）

| 优先级 | 任务 | 工程量 |
|--------|------|--------|
| ⭐⭐⭐ | Blob Arena 段死亡重写策略落地 | 3-4 周 |
| ⭐⭐ | 列压缩（PFOR / RLE / Dictionary） | 4-6 周 |
| ⭐⭐ | 冷热分层（RAM → NVMe → S3） | 8-10 周 |
| ⭐ | SIMD 全列扫描（AVX2 / AVX-512） | 2-3 周 |

### 4.4 不建议做（守住设计哲学）

| 想法 | 为什么不做 |
|------|-----------|
| SQL 解析器 | 上游 `database.md` 明确拒绝；引入 = 注入风险 + parser 维护地狱 |
| B-Tree 二级索引 | 与 SoA 顺序写冲突；用谓词 planner + 类型键唯一索引覆盖 |
| MVCC | 与 Bump Arena 冲突；可选乐观锁（cmpxchg 版本号）已经够用 |
| WAL | 违背"零隐式状态"原则；epoch + 不可变段是等价方案 |
| 跨主机复制 / 共识 | 不是 sa-db 的使命；要分布式去用 sa_plugin_dbnet |
| 通用 query 优化器 | 上游设计明示"预编译"；优化在 register 阶段做，不在执行期 |
| 加 GC | 与 SA 哲学冲突；段死亡重写已是足够方案 |

---

## 5. 战略层面的建议

### 5.1 重写一次 README 的"是什么 / 不是什么"

当前 README 第一句："provides a local, file-backed column store" 不够诚实——它实际上是一个**带 ERP planner、字典 intern、blob_eq 业务键、事务、读句柄缓存的嵌入式列式 OLAP 引擎**。建议改写为：

> `sa_plugin_db` is SA's embedded columnar OLAP engine for ERP and reporting workloads.
> It provides typed-key writes, predicate planners, blob/dictionary storage, single-table transactions, and read-handle snapshot queries — but **does not implement SQL, B-trees, MVCC, WAL, or distributed replication** by design.

### 5.2 与上游 `database.md` 同步

当前插件已经长出了 `database.md` 没设计的能力（read handles / typed key writes / ERP planners / tx_dict_intern）。建议：

1. **要么**：把这些新增能力回填到 `database.md` 作为 v0.2 修订
2. **要么**：声明插件已经分叉，`database.md` 仅描述 sa-db v0.1 核心；插件自有路线图

不同步则文档读者会被误导。**推荐选 1**。

### 5.3 把 demo 从 ERP 解耦

当前 `benchmark_test/` 里有大量明显 ERP 痕迹（采购、库存、订单等命名）。如果想吸引 OLAP / 报表 / 边缘日志聚合 / IoT 时序场景的用户，需要：

1. 在 `examples/` 加 3-5 个非 ERP 场景（边缘指标聚合 / IoT 设备读数 / 日志统计）
2. 不要让"ERP planner"变成对外宣传的主词，应该是"通用谓词 planner"
3. 把 `u64+date+decimal_i64` 这类强业务命名改成中性如 `u64+i64+i64_with_semantic_tags`

### 5.4 性能 benchmark 持续运行

`db_comparison.md` 是宝贵资产。建议：

1. 进 CI，每次 release 自动跑
2. 加更多 workload：1K / 10K / 100K / 1M 行的递增基准
3. 加 OLAP 场景 benchmark（GROUP BY + 多列 SUM）
4. 加并发 benchmark 的 worker 数扫描（1 / 4 / 16 / 64）
5. 与 DuckDB（嵌入式 OLAP 真正对手）也对比一组

vs SQLite 已经能看出 db 插件的优势区；与 DuckDB 比能定位 OLAP 维度真实水准。

### 5.5 一句话定位（草案）

```
sa-db: embedded columnar OLAP for SA — millisecond read handles,
       predicate planners, zero-trust grants, no SQL, no B-tree, no WAL.
```

---

## 6. 总结

**完成度评分**：

| 维度 | 评分 |
|------|------|
| 原始 16 项使命 | ✅ 100% |
| 列式 OLAP 广义使命 | ⚠️ ~55-60% |
| 设计文档与实现一致性 | ⚠️ 文档落后于实现 |
| ABI 表面成熟度 | 🔴 严重组合爆炸，需收敛 |
| 崩溃恢复证明 | 🔴 文档声称，未验证 |
| 性能（vs SQLite） | ✅ 写 / 并发占优，⚠️ 元操作落后 |
| 性能（vs DuckDB） | ❓ 未对比 |

**最重要的 3 件事**（按优先级）：

1. **ABI 收敛**（§3.1）—— 285 个 extern 会把项目维护成本压垮
2. **崩溃恢复测试 + 文档化**（§3.2）—— DB 的硬基础线，不能跳
3. **JOIN 能力**（§3.4）—— ERP 场景实用度的最大杠杆

**最大的战略风险**：插件已实质走向"ERP OLAP 专用 + 通用列存兼用"，但未明示。如果不在 0.2 之前明确定位、对齐文档、修剪 ABI、补完恢复测试，**后续每加一个 feature 都会让代码债 / 文档债 / Agent 学习成本继续累积**，越拖越难收尾。

但好消息是：**核心方向是对的**，与上游设计哲学一致，未做 SQL / B-Tree / MVCC / WAL 这些会拉进无尽泥潭的事。当前需要的不是"再加功能"，是"先收尾、补基础线、再加 JOIN / nullable / 压缩"这种纪律性的工程节奏。

---

## 附录：评估参考文件清单

| 文件 | 用途 |
|------|------|
| `sap.json` | 插件清单 / 权限 |
| `db.sai` (288 行 / 285 extern) | SA 侧 ABI 契约 |
| `db.sal` (1941 行 / 315 宏与常量) | SA 侧 facade |
| `src/table.zig` (17,306 行) | 表与段存储核心 |
| `src/db_saasm_api.zig` (9,428 行) | C-ABI 入口集 |
| `src/db_stub.zig` (3,986 行) | qmod 执行评估器 |
| `src/plugin.zig` (658 行) | descriptor / skills |
| `src/schema.zig` (495 行) | `.sadb-schema` 解析 |
| `progress.md` | 16 项 feature 进展 + 历史 smoke 列表 |
| `README.md` / `README_cn.md` | 用户面文档 |
| `docs/db_plugin_design.md` | 当前设计声明 |
| `docs/qmod_examples.md` | qmod 用例 |
| `sci/docs/database.md` | 上游 sa-db 设计源头 |
| `sci/docs/db_comparison.md` | vs SQLite benchmark |
| `sci/docs/db_plugin_evaluation.md` | 历史评估快照（如有） |
