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

当前版本已经具备文件级原子替换：写入 schema、meta、列段文件、索引文件、snapshot/restore 目标文件时，会先写入同目录临时文件，执行文件同步，再通过原子 rename 替换活跃文件；在 Linux 上会尽力同步父目录。表提交由 active manifest 选择，manifest 指向版本化元数据文件（`<table>.meta.<epoch>`）；修改已有列数据时会写入新的版本化列文件，再推进 manifest，因此 manifest 替换前崩溃仍可读取旧 epoch。Qmod 读写路径也使用同一套 active-manifest 协议。当前已支持持久化 `u64 -> row` 索引，用于点查和 `count_u64_cmp` 比较计数，并会在 ingest/update/compact/qmod 写入后重建。`sa_db_create_u64_index(..., unique=1)` 现在会作为真正的唯一约束：创建唯一索引时会拒绝已有重复值，后续列式 ingest、固定宽度行式 insert、update、compact 和 Qmod commit 如果产生重复 key，会返回 `SA_DB_ERR_CONSTRAINT`，active manifest 保持在上一个有效 epoch。`verify` 会校验 schema 哈希、列段 SHA-256、索引 SHA-256、元数据记录字节数，以及 `segment.rows * column.stride` 推导出的期望字节数。`recover` 会扫描版本化元数据文件，选择最高的有效 epoch 重建 manifest，用于处理中断提交后 manifest 损坏或丢失的情况。

面向 ERP 的行式写入已经提供第一版接口：`sa_db_insert_row` / `DB_INSERT_ROW` 接收一条按照当前 schema 列 stride 顺序排列的固定宽度行数据。内部会把行数据切分成各列切片，并复用列式 ingest 提交流程，因此会推进表 epoch，并重建已有的持久化 `u64` 索引。`sa_db_get_row_u64_key_handle` / `DB_GET_ROW_U64_KEY_HANDLE` 支持在读句柄快照上按唯一 `u64` key 读取整行，并把固定宽度行数据复制到调用方 buffer。`sa_db_delete_u64_key` / `DB_DELETE_U64_KEY` 支持按唯一 `u64` key 删除一行，目标列必须已经建立唯一 `u64` 索引，因此是主键语义而不是删除普通非唯一匹配；删除会把剩余行重写到新的列段，重建索引并推进 epoch，key 不存在时返回 `SA_DB_ERR_NOT_FOUND`。

这仍不是完整的 SQLite 级 ACID/WAL。面向中小型 ERP 的下一阶段需要继续补齐事务提交语义、通用主键/二级索引、upsert、范围查询 handle、nullable/decimal/date/string-dict 类型，以及 SA 编写的 ERP 场景 benchmark。当前 `u64` 唯一索引、固定宽度行 insert、按唯一 key get/delete 已经可作为主键语义的第一步。

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
