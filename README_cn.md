# SA 数据库插件 (sa_plugin_db) 详细使用教程

`sa_plugin_db` 是为 SA 项目提供的一个**本地、文件支持、基于列式存储**的数据库插件。该插件遵循 `sa.plugin/1` 规范，在设计上受到严格的安全沙箱限制：它仅被允许在项目工作目录（`$PROJECT/**`）内进行文件读、写、创建和删除，**无网络访问、无环境变量读取、禁止衍生新进程**，以确保数据库操作在受限环境中的绝对安全。

---

## 目录
1. [插件配置解析 (`sap.json`)](#1-插件配置解析-sapjson)
2. [安装与验证](#2-安装与验证)
3. [数据库 Schema 规范定义](#3-数据库-schema-规范定义)
4. [CLI 命令行工具参考](#4-cli-命令行工具参考)
5. [存储布局剖析](#5-存储布局剖析)
6. [Qmod (Query Module) 开发与安全机制](#6-qmod-query-module-开发与安全机制)
7. [完整实战演练：从零到查询](#7-完整实战演练从零到查询)

---

## 1. 插件配置解析 (`sap.json`)

在 `/home/vscode/projects/sa_plugins/sa_plugin_db/sap.json` 中定义了该插件的元数据和声明：
* **`name` / `version`**: `db` / `0.1.0`。
* **`abi`**: 限定所需的 SAASM 编译器版本为 `>=0.4.0`。
* **`artifacts`**: 针对 Linux x86_64 构建产物为 `zig-out/lib/libdb.so`。
* **`skills`**: 导出 `database` 能力，使得宿主 CLI 自动加载 `sa db` 命令子集。
* **`permissions`**: 
  - **`fs`**: 允许在项目根目录（`$PROJECT/**`）执行 `read`, `write`, `create`, `delete`。
  - **`net` / `env`**: 禁止（空数组 `[]`）。
  - **`process`**: 禁止衍生子进程（`spawn: false`）。

---

## 2. 安装与验证

### 2.1 编译插件
插件使用 Zig 语言开发，安装前需要先进行编译：
```bash
zig build
```
编译成功后，将在 `zig-out/lib/` 目录下生成 `libdb.so`（与 `sap.json` 中 `artifacts` 匹配）。

### 2.2 开发模式安装
将当前插件以开发（本地）模式注册到 SA 环境中：
```bash
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_db
```

### 2.3 验证安装状态
运行以下命令检查插件是否已成功启用并导出了对应的 `database` 能力：
```bash
# 检查插件列表
SA_PLUGIN_DEV=1 sa plugin list

# 检查技能注册情况
SA_PLUGIN_DEV=1 sa skills
```
若输出中包含 `db` 插件和 `database` 技能详情（如 `db init`、`db lock` 等命令），则代表安装成功。

---

## 3. 数据库 Schema 规范定义

在使用数据库前，你需要为数据表定义一个结构体描述文件，扩展名为 `.sadb-schema`。

### 3.1 语法规则
Schema 文件采用类似 C 语言宏定义的指令集（`#def`）：
1. **`MAX_ROWS`** (必填)：定义该表在物理上的最大行数容量。
2. **`COL_<COLUMN_NAME>_STRIDE`** (必填)：定义列字段的内存步长（字节大小），且必须声明数据类型注释以进行 ABI 映射。
3. **数据类型注释**：在一行定义的末尾使用 `//` 注释明确列的数据类型。支持的原始类型（PrimType）包括：
   * 1 字节：`i1`, `i8`, `u8`
   * 2 字节：`i16`, `u16`
   * 4 字节：`i32`, `u32`, `f32`
   * 8 字节：`i64`, `u64`, `f64`, `ptr`, `blob_handle`
   * 16 字节：`v128`
4. **`TABLE_ROW_BYTES`** (可选)：声明表的一行总字节大小。如省略，编译器会根据所有列的 `STRIDE` 自动计算。

### 3.2 示例 Schema (`flash_sale.sadb-schema`)
```text
#def MAX_ROWS = 8
#def COL_ID_STRIDE = 8 // u64 : 商品ID
#def COL_PRICE_STRIDE = 4 // f32 : 商品价格
```

---

## 4. CLI 命令行工具参考

`sa_plugin_db` 提供了一套完整的命令行工具来管理表的物理周期、维护状态和执行查询。

| 命令 | 格式 | 说明 |
| :--- | :--- | :--- |
| **初始化表结构** | `sa db init <schema.sadb-schema>` | 编译 schema，并在当前目录下生成供程序引用的 `<table_name>.sai` 接口定义文件。 |
| **导入数据** | `sa db ingest <table> <csv\|jsonl>` | 将 CSV 或 JSONL 数据转为列存段文件，追加到表中。 |
| **查询元数据** | `sa db inspect <table\|hash>` | 查询指定表的信息，或查看指定 SHA-256 注册 Query 的元数据。 |
| **查看状态** | `sa db status <table>` | `inspect <table>` 的别名，返回表的基本运行指标。 |
| **校验数据** | `sa db verify <table>` | 计算检验和，验证 schema 哈希、数据段哈希、行数和段文件大小是否一致。 |
| **数据合并** | `sa db compact <table>` | 将分散的多个列数据段文件（Segment）重写合并为一个单段文件，提高读取吞吐。 |
| **建立快照** | `sa db snapshot <table>` | 备份表当前的元数据、结构和所有数据段到 `.sa/db/snapshots/<table>/<epoch>/`。 |
| **恢复快照** | `sa db restore <table> <epoch>` | 将表数据回滚至指定的 snapshot epoch。 |
| **锁定表** | `sa db lock <table>` | 将表设为只读。锁定后，拒绝任何写入/导入操作，防止数据被意外篡改。 |
| **解锁表** | `sa db unlock <table>` | 重新校验表数据一致性，清除只读标志，恢复表的写入和导入功能。 |
| **注册 Query** | `sa db register <query.sa>` | 将编写的 `.sa` 查询代码（Qmod）进行编译注册，分配 SHA-256 唯一指纹。 |
| **执行 Query** | `sa db exec <hash> [--params <file>]` | 执行已注册的 Qmod。可通过可选的 `--params` 文件传递二进制运行参数。 |

---

## 5. 存储布局剖析

当一个名为 `flash_sale` 的表初始化并写入数据后，工作目录下的物理文件排布如下：

```text
├── flash_sale.sadb-schema        # 源表 Schema 配置文件
├── flash_sale.sai                # 由 `sa db init` 生成的 SA 编译器接口文件
├── flash_sale.meta               # 激活表的 JSON 格式元数据 (版本、行数、列定义、段指纹等)
├── flash_sale.col0.0.dat         # 列 0 (ID) 的第 0 个物理数据段文件
├── flash_sale.col1.0.dat         # 列 1 (PRICE) 的第 0 个物理数据段文件
├── flash_sale.idx.u64.0.3.dat    # u64 单列索引文件（如存在）
├── flash_sale.idx.u64_pair.0.1.4.dat # u64 组合索引文件（如存在）
├── flash_sale.dict.member_status.2.dat # 低基数字符串字典文件（如存在）
└── .sa/
    └── db/
        ├── qmods/
        │   ├── <hash>.qmod       # 编译生成的已注册 Query 载荷
        │   └── <hash>.meta.json  # Query 的权限声明和注册元数据
        └── snapshots/
            └── flash_sale/
                └── <epoch>/      # 指定备份世代的元数据与数据段副本
```

---

### 当前可靠性状态

当前版本已经具备文件级原子替换：写入 schema、meta、列段文件、索引文件、字典文件、snapshot/restore 目标文件时，会先写入同目录临时文件，执行文件同步，再通过原子 rename 替换活跃文件；在 Linux 上会尽力同步父目录。SA ABI 层有进程内 mutex，table 层现在还会使用每表一个 advisory 写锁文件（`<table>.write.lock`），让 CLI、qmod 和 extern 写入在跨进程场景下也按单表串行执行；锁文件会被 `removeTable` 保留，避免删除已加锁文件后其他进程重新创建同名文件而破坏锁语义。表提交由 active manifest 选择，manifest 指向版本化元数据文件（`<table>.meta.<epoch>`）；修改已有列数据时会写入新的版本化列文件，再推进 manifest，因此 manifest 替换前崩溃仍可读取旧 epoch。单表事务提交现在会在写 replacement artifact 前写入 `<table>.tx.<epoch>.pending`，在事务版本化 meta 落盘后写入可校验的 `<table>.tx.<epoch>.commit`；`recover` 会忽略只有 pending marker 的事务 meta，校验 commit marker 中记录的 meta hash/byte count，并在 active manifest 陈旧或损坏时补全已提交事务，同时清理 stale pending marker。Qmod 读写路径也使用同一套 active-manifest 协议。新写入的列段、索引和字典 artifact metadata 会记录 whole-file SHA-256、字节数和 64KB block-level SHA-256 列表；旧 metadata 没有 block hash 仍可读取。列段会在 `verify/recover`、读快照打开和 qmod 读写路径中校验块级 hash；索引会在 `verify/recover` 和读快照打开时校验；字典会在 `verify/recover` 和字典读取时校验。当前已支持持久化 `u64 -> row`、signed-order `i64 -> row` 和 `u64_pair -> row` 索引，用于点查、范围、组合键分页和比较计数，并会在 ingest/update/compact/qmod 写入后重建。低基数字符串字典文件同样会被版本化、记录 SHA-256 和 entry count、纳入 snapshot/restore/verify/recover。`sa_db_create_u64_index(..., unique=1)` 现在会作为真正的唯一约束：创建唯一索引时会拒绝已有重复值，后续列式 ingest、固定宽度行式 insert、update、compact 和 Qmod commit 如果产生重复 key，会返回 `SA_DB_ERR_CONSTRAINT`，active manifest 保持在上一个有效 epoch。`sa_db_create_u64_pair_index(..., unique=1)` 对两列 tuple 应用同样的约束，可用于 `(order_id,line_no)`、`(product_id,warehouse_id)` 等 ERP 组合键。`verify` 会校验 schema 哈希、列段 SHA-256、列段 block SHA-256、索引 SHA-256、索引 block SHA-256、索引形状/排序、字典 SHA-256、字典 block SHA-256、元数据记录字节数、字典条目数，以及 `segment.rows * column.stride` 推导出的期望字节数。`recover` 会扫描版本化元数据文件，选择最高的有效 epoch 重建 manifest，用于处理中断提交后 manifest 损坏或丢失的情况。

读句柄查询现在新增 `sa_db_snapshot_info_handle` / `DB_SNAPSHOT_INFO_HANDLE` 和 `sa_db_column_info_handle` / `DB_COLUMN_INFO_HANDLE`，用于在不解析 JSON meta 的情况下读取快照行数、列数、行宽、epoch、列 stride、primitive type code 和元数据字符串长度。`db.sal` 暴露的 `SA_DB_TYPE_I1/I8/I16/I32/I64/U8/U16/U32/U64/F32/F64/PTR/BLOB_HANDLE/V128` 与 schema 编译器枚举一致。ERP 上层可以继续使用 primitive 列存，同时通过逻辑类型 helper 表达业务字段：decimal/money 编码为 scaled `i64`，date 编码为 epoch days，timestamp 编码为 epoch milliseconds 或 microseconds，boolean 规范化为 `0/1`，nullable 字段使用 sidecar null bitmap。当前这些 helper 不改变物理文件格式，因此已有 `i64/u64` 索引、范围查询、投影和固定宽度 row buffer 都可以继续复用。

新增的 SA ABI / SAL 宏包括 `sa_db_decimal_from_parts` / `DB_DECIMAL_FROM_PARTS`、`sa_db_decimal_to_parts` / `DB_DECIMAL_TO_PARTS`、`sa_db_date_from_ymd` / `DB_DATE_FROM_YMD`、`sa_db_date_to_ymd` / `DB_DATE_TO_YMD`、`sa_db_timestamp_ms_from_parts` / `DB_TIMESTAMP_MS_FROM_PARTS`、`sa_db_timestamp_ms_to_parts` / `DB_TIMESTAMP_MS_TO_PARTS`、`sa_db_timestamp_us_from_parts` / `DB_TIMESTAMP_US_FROM_PARTS`、`sa_db_timestamp_us_to_parts` / `DB_TIMESTAMP_US_TO_PARTS`、`sa_db_bool_encode` / `DB_BOOL_ENCODE`、`sa_db_bool_decode` / `DB_BOOL_DECODE`、`sa_db_null_bitmap_required_bytes` / `DB_NULL_BITMAP_REQUIRED_BYTES`、`sa_db_null_bitmap_clear` / `DB_NULL_BITMAP_CLEAR`、`sa_db_null_bitmap_set` / `DB_NULL_BITMAP_SET`、`sa_db_null_bitmap_get` / `DB_NULL_BITMAP_GET`。例如 `DB_DECIMAL_FROM_PARTS(1, 1, 0, 2)` 会把 `-1.00` 编码为 `-100`；`2024-02-29` 会编码为 epoch day `19782`，调用方可以直接在对应的 `i64` 列上建立 signed-order 索引。

低基数字符串现在通过表级字典支持，而不是完整 variable-width 字符串列。`sa_db_dict_intern` / `DB_DICT_INTERN` 会把非空字节串（例如 `active`、`paid`、`warehouse_a`、`invoice`）映射为命名字典中的稳定 1-based `u64` ID；ID `0` 预留给上层表达 null/unknown 等语义。重复 intern 会返回已有 ID，不推进 epoch。`sa_db_dict_lookup` 查询已有 ID，`sa_db_dict_value_len` 返回 ID 对应字符串长度，`sa_db_dict_value_copy` 把字符串复制到调用方 buffer。ERP 行数据中仍存普通 `u64` ID，因此状态、分类、单据类型等字段可以复用现有 `u64` 索引、范围读取、投影和 row API。

读句柄查询也支持 `sa_db_range_u64_handle` / `DB_RANGE_U64_HANDLE`，用于对已有持久化 `u64` 索引的列执行闭区间 `[min, max]` 范围分页。调用方传入 `offset`、`limit` 和 `u64` row-index 输出 buffer，接口返回总匹配数 `total` 与实际写入数量 `written`，输出顺序为索引顺序。该接口要求目标列已经建立 `u64` 索引，因此可通过二分边界完成分页，适合 ERP 中按订单号、日期编码、客户编号等索引字段取列表窗口。`sa_db_create_i64_index` / `DB_CREATE_I64_INDEX` 以及 `sa_db_range_i64_handle` / `DB_RANGE_I64_HANDLE`、`DB_COUNT_I64_CMP_HANDLE`、`DB_FIND_I64_HANDLE`、`DB_GET_I64_HANDLE`、`DB_MIN_I64_HANDLE`、`DB_MAX_I64_HANDLE` 为 `i64` 列提供同样的 signed-order 索引读取能力，适合金额分、余额、时间戳等可排序 signed 编码；负数会按 signed 顺序排在 0 之前，而不是被当作超大的无符号数。`sa_db_range_u64_null_bitmap_handle` / `DB_RANGE_U64_NULL_BITMAP_HANDLE` 和 `sa_db_range_i64_null_bitmap_handle` / `DB_RANGE_I64_NULL_BITMAP_HANDLE` 会在索引范围候选集上先应用 sidecar null bitmap，再计算 `total/offset/limit`，因此分页语义是过滤后的结果，而不是 SA 代码拿到一页后再丢行。`sa_db_range_decimal_i64_handle` / `DB_RANGE_DECIMAL_I64_HANDLE`、`sa_db_range_decimal_i64_null_bitmap_handle` / `DB_RANGE_DECIMAL_I64_NULL_BITMAP_HANDLE` 直接接收 decimal parts 与 scale，编码为 signed scaled `i64` 后使用 signed index；`sa_db_range_date_handle` / `DB_RANGE_DATE_HANDLE`、`sa_db_range_date_null_bitmap_handle` / `DB_RANGE_DATE_NULL_BITMAP_HANDLE` 直接接收 Y-M-D 日期范围并编码为 epoch days。无效日期或 decimal parts 会返回 `SA_DB_ERR_INVALID_ARGUMENT`，不会继续执行范围查询。`sa_db_create_u64_pair_index` / `DB_CREATE_U64_PAIR_INDEX` 会在两个 `u64` 列上建立持久化组合索引，`unique=1` 约束整个 `(key1,key2)` tuple；`sa_db_find_u64_pair_handle` / `DB_FIND_U64_PAIR_HANDLE` 做精确组合键点查，`sa_db_range_u64_pair_handle` / `DB_RANGE_U64_PAIR_HANDLE` 在固定第一键的前提下对第二键做闭区间分页，适合订单明细、仓库库存、客户日期窗口等 ERP 列表。`sa_db_get_row_handle` / `DB_GET_ROW_HANDLE` 可把这些 row-index 继续物化为调用方 buffer 中的一条固定宽度整行。`sa_db_project_rows_handle` / `DB_PROJECT_ROWS_HANDLE` 面向列表页批量投影：传入 row-index 数组和 column-index 数组，只复制需要的列；输出按输入行顺序逐行打包，每行内部按请求列顺序拼接列字节。接口返回 `written_rows` 和 `required_bytes`，buffer 太小时返回 `SA_DB_ERR_CURSOR_OVERFLOW` 并填充 `required_bytes`。

面向 ERP 的行式写入已经提供第一版接口：`sa_db_insert_row` / `DB_INSERT_ROW` 接收一条按照当前 schema 列 stride 顺序排列的固定宽度行数据。内部会把行数据切分成各列切片，并复用列式 ingest 提交流程，因此会推进表 epoch，并重建已有的持久化 `u64`、`i64` 和 `u64_pair` 索引。`sa_db_tx_begin` / `DB_TX_BEGIN` 提供单表写事务句柄；`DB_TX_INSERT_ROW`、`DB_TX_UPSERT_ROW_U64_KEY`、`DB_TX_DELETE_U64_KEY` 先修改内存中的事务镜像，直到 `sa_db_tx_commit` / `DB_TX_COMMIT` 才写出一个新的 replacement segment、重建所有索引，并只推进一次 active manifest。pending/commit marker 让 `recover` 能区分未完成事务 meta 和 manifest 更新中断但已经提交的事务 meta。若 commit 因唯一索引重复等原因失败，旧 manifest 仍然可见，事务句柄会关闭；`sa_db_tx_rollback` / `DB_TX_ROLLBACK` 会丢弃未提交镜像，不发布任何行。当前这是单表、单写者事务，读句柄仍只看到已提交快照。`sa_db_upsert_row_u64_key` / `DB_UPSERT_ROW_U64_KEY` 支持按唯一 `u64` key 原子 upsert 固定宽度整行：目标列必须已经建立唯一 `u64` 索引；key 存在时重写整表为新的列段、重建索引并推进 epoch，`out_inserted=0`；key 不存在时追加新行并返回 `out_inserted=1`。调用传入的 `expected` 必须等于行数据里 key 列编码出的 `u64` 值，否则返回 `SA_DB_ERR_INVALID_FORMAT`，不会提交新 epoch。`sa_db_get_row_u64_key_handle` / `DB_GET_ROW_U64_KEY_HANDLE` 支持在读句柄快照上按唯一 `u64` key 读取整行，并把固定宽度行数据复制到调用方 buffer。`sa_db_delete_u64_key` / `DB_DELETE_U64_KEY` 支持按唯一 `u64` key 删除一行，目标列必须已经建立唯一 `u64` 索引，因此是主键语义而不是删除普通非唯一匹配；删除会把剩余行重写到新的列段，重建索引并推进 epoch，key 不存在时返回 `SA_DB_ERR_NOT_FOUND`。

`sa_db_dict_intern` / `DB_DICT_INTERN` 是 ERP 字符串数据模型的第一层：字典适合状态、分类、仓库、支付方式、单据类型等重复值集合，不是通用 varchar/blob 存储。字典本身是表 artifact，会随 snapshot、restore、verify、recover、lock、unlock 和 remove 一起维护一致性。

这仍不是完整的 SQLite 级 ACID/WAL，也还没有多表事务。面向中小型 ERP 的下一阶段需要继续扩大故障注入矩阵、补齐可选 WAL、更多主键/二级索引形态、更丰富的 typed column family、timestamp 专用范围包装，以及 SA 编写的 ERP 场景 benchmark。当前 primitive 类型元数据、逻辑类型 encode/decode helper、decimal/date typed range、`u64/i64` 范围查询的 null bitmap 分页前过滤、`u64` 唯一索引、`i64` signed 范围/点查/比较读取、`u64_pair` 组合键点查与分页、低基数字符串字典、范围分页、批量投影读取、固定宽度行 insert/upsert、带恢复 marker 的单表批量事务、列段/索引/字典 block checksum、按 row-index 或唯一 key get、按唯一 key delete、单表跨进程写锁已经可作为主键语义、类型感知行编码和列表页读取的第一步。

---

## 6. Qmod (Query Module) 开发与安全机制

Qmod 是运行在本地受限沙箱评估器中的高级查询程序。

### 6.1 Grants (权限声明)
为了防止代码越权，每个 Qmod 必须在文件顶部通过 `grants [...]` 显式声明其所需的权限。如果代码指令访问了未授权 of 表或列，`sa db register` 将拒绝注册。
* `db_read:<table>`：允许读取该表的列存指针数据。
* `db_write:<table>`：允许写入该表的数据。
* `db_atomic_cursor:<table>`：允许使用原子游标迭代。

### 6.2 编写规则
* **主入口**：必须使用 `@main` 作为主函数入口。
* **参数传递**：参数通常接收列存的数据指针 `&col_name: ptr` 和长度 `len: u64`。
* **运算指令**：支持二进制整数运算（`add`, `sub`, `mul`, `and`, `or`, `xor`, `shl`, `lshr` 等）和比较运算（`eq`, `ne`, `ult`, `ule`, `ugt`, `uge` 等）。
* **浮点比较**：支持基于 IEEE-754 表达的 `fcmp_gt`、`fcmp_lt` 等比较指令。

---

## 7. 完整实战演练：从零到查询

本节演示如何建立一个名为 `flash_sale` 的表，导入数据，并编写一个 Qmod 查询计算所有 `ID` 的总和。

### 步骤 1：定义 Schema
在当前目录下创建 `flash_sale.sadb-schema`：
```text
#def MAX_ROWS = 8
#def COL_ID_STRIDE = 8 // u64
#def COL_PRICE_STRIDE = 4 // f32
```

### 步骤 2：初始化与生成接口
```bash
SA_PLUGIN_DEV=1 sa db init flash_sale.sadb-schema
```
这将在当前工作目录生成编译所需的接口文件 `flash_sale.sai`。

### 步骤 3：准备并导入数据
创建数据文件 `rows.csv`：
```csv
ID,PRICE
1,9.5
2,10.25
5,120.00
```
导入该 CSV 数据：
```bash
SA_PLUGIN_DEV=1 sa db ingest flash_sale rows.csv
```
此时通过 `sa db status flash_sale` 命令，可以看到当前行数（`row_count: 3`）以及活跃的数据段。

### 步骤 4：编写 Qmod 查询程序
创建名为 `sum_ids.query.sa` 的查询文件，目标是遍历 `ID` 列（列0）并累加其数值：
```sa
grants [db_read:flash_sale]
@main(&col_id: ptr, len: u64) -> u64:
L_ENTRY:
    idx = add 0, 0
    sum = add 0, 0
    jmp L_COND
L_COND:
    cond = ult idx, len
    br cond -> L_BODY, L_EXIT
L_BODY:
    offset = mul idx, 8
    value = load col_id+offset as u64
    sum = add sum, value
    idx = add idx, 1
    jmp L_COND
L_EXIT:
    return sum
```

### 步骤 5：注册并运行 Qmod
1. **注册该 Query**：
   ```bash
   register_res=$(SA_PLUGIN_DEV=1 sa db register sum_ids.query.sa)
   echo "$register_res"
   ```
   输出中会提供本次注册计算出来的唯一 `Hash` 值（例如 `a1b2c3d4...`）。

2. **执行该 Query**：
   使用获取到的 Hash 值（假设为 `a1b2c3d4...`）：
   ```bash
   SA_PLUGIN_DEV=1 sa db exec a1b2c3d4...
   ```
   **预期输出结果**：
   ```text
   Executed: main
   result_u64: 8
   ```
   （计算逻辑：1 + 2 + 5 = 8）

### 步骤 6：表锁定运维防篡改
当数据录入完毕后，锁定该表以进入只读归档状态：
```bash
# 锁定表
SA_PLUGIN_DEV=1 sa db lock flash_sale

# 再次验证锁定状态
SA_PLUGIN_DEV=1 sa db verify flash_sale
```
锁定后若尝试写入或重新 `ingest`，系统将返回错误 `error[SA-DB-CLI]: DB table is locked`。需要写入时，可通过 `sa db unlock flash_sale` 解锁。

---

*说明：在实际 SA 应用中，你可以使用自动生成的 `.sai` 头文件来配合程序开发，而以上的 CLI 命令为离线管理和 Query 的调试提供了核心支撑。*
