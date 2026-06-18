# SA DB Plugin

`sa_plugin_db` is the native database plugin for SA. It provides a local,
file-backed column store with SA-facing `sai` and `sal` interfaces.

The current development API is intentionally breaking: the old direct query
ABI has been removed. Query code must use read handles.

## Plugin Metadata

- Plugin: `db` v0.1.0
- Manifest: `sap.json`
- Native library: `zig-out/lib/libdb.so`
- Public interfaces: `db.sai`, `db.sal`
- Skill: `database`
- Permissions: project-local filesystem read/write/create/delete only; no net,
  no env access, no process spawning

## Build And Install

```bash
zig build test
zig build
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_db
sa plugin list
```

## SA-Facing API

The plugin exposes `sai` and `sal` interfaces through `sap.json`:

```json
"interfaces": {
  "sai": { "path": "db.sai" },
  "sal": { "path": "db.sal" }
}
```

Core native calls:

- `sa_db_init_schema`
- `sa_db_remove_table`
- `sa_db_ingest_columns`
- `sa_db_insert_row`
- `sa_db_upsert_row_u64_key`
- `sa_db_update_row_u64_key`
- `sa_db_upsert_row_u32_key`
- `sa_db_update_row_u32_key`
- `sa_db_upsert_row_i32_key`
- `sa_db_update_row_i32_key`
- `sa_db_upsert_row_u8_key`
- `sa_db_update_row_u8_key`
- `sa_db_upsert_row_i8_key`
- `sa_db_update_row_i8_key`
- `sa_db_upsert_row_u16_key`
- `sa_db_update_row_u16_key`
- `sa_db_upsert_row_i16_key`
- `sa_db_update_row_i16_key`
- `sa_db_upsert_row_i64_key`
- `sa_db_update_row_i64_key`
- `sa_db_upsert_row_u64_pair_key`
- `sa_db_update_row_u64_pair_key`
- `sa_db_upsert_row_u64_i64_pair_key`
- `sa_db_update_row_u64_i64_pair_key`
- `sa_db_upsert_row_blob_eq_key`
- `sa_db_update_row_blob_eq_key`
- `sa_db_tx_begin`
- `sa_db_tx_insert_row`
- `sa_db_tx_dict_intern`
- `sa_db_tx_blob_put`
- `sa_db_tx_upsert_row_u64_key`
- `sa_db_tx_update_row_u64_key`
- `sa_db_tx_delete_u64_key`
- `sa_db_tx_upsert_row_u32_key`
- `sa_db_tx_update_row_u32_key`
- `sa_db_tx_delete_u32_key`
- `sa_db_tx_upsert_row_i32_key`
- `sa_db_tx_update_row_i32_key`
- `sa_db_tx_delete_i32_key`
- `sa_db_tx_upsert_row_u8_key`
- `sa_db_tx_update_row_u8_key`
- `sa_db_tx_delete_u8_key`
- `sa_db_tx_upsert_row_i8_key`
- `sa_db_tx_update_row_i8_key`
- `sa_db_tx_delete_i8_key`
- `sa_db_tx_upsert_row_u16_key`
- `sa_db_tx_update_row_u16_key`
- `sa_db_tx_delete_u16_key`
- `sa_db_tx_upsert_row_i16_key`
- `sa_db_tx_update_row_i16_key`
- `sa_db_tx_delete_i16_key`
- `sa_db_tx_upsert_row_i64_key`
- `sa_db_tx_update_row_i64_key`
- `sa_db_tx_delete_i64_key`
- `sa_db_tx_upsert_row_u64_pair_key`
- `sa_db_tx_update_row_u64_pair_key`
- `sa_db_tx_delete_u64_pair_key`
- `sa_db_tx_upsert_row_u64_i64_pair_key`
- `sa_db_tx_update_row_u64_i64_pair_key`
- `sa_db_tx_delete_u64_i64_pair_key`
- `sa_db_tx_upsert_row_blob_eq_key`
- `sa_db_tx_update_row_blob_eq_key`
- `sa_db_tx_delete_blob_eq_key`
- `sa_db_tx_commit`
- `sa_db_tx_rollback`
- `sa_db_create_u64_index`
- `sa_db_create_i64_index`
- `sa_db_create_u32_index`
- `sa_db_create_i32_index`
- `sa_db_create_u8_index`
- `sa_db_create_i8_index`
- `sa_db_create_u16_index`
- `sa_db_create_i16_index`
- `sa_db_create_f32_index`
- `sa_db_create_f64_index`
- `sa_db_create_u64_pair_index`
- `sa_db_create_u64_i64_pair_index`
- `sa_db_create_blob_eq_index`
- `sa_db_create_blob_token_index`
- `sa_db_create_blob_prefix_index`
- `sa_db_create_blob_contains_index`
- `sa_db_dict_intern`
- `sa_db_dict_lookup`
- `sa_db_dict_value_len`
- `sa_db_dict_value_copy`
- `sa_db_dict_lookup_handle`
- `sa_db_dict_value_len_handle`
- `sa_db_dict_value_copy_handle`
- `sa_db_blob_put`
- `sa_db_blob_value_len`
- `sa_db_blob_value_copy`
- `sa_db_blob_value_len_handle`
- `sa_db_blob_value_copy_handle`
- `sa_db_delete_u64_key`
- `sa_db_delete_u32_key`
- `sa_db_delete_i32_key`
- `sa_db_delete_u8_key`
- `sa_db_delete_i8_key`
- `sa_db_delete_u16_key`
- `sa_db_delete_i16_key`
- `sa_db_delete_i64_key`
- `sa_db_delete_u64_pair_key`
- `sa_db_delete_u64_i64_pair_key`
- `sa_db_delete_blob_eq_key`
- `sa_db_snapshot`
- `sa_db_restore`
- `sa_db_recover`
- `sa_db_verify`
- `sa_db_compact`
- `sa_db_lock`
- `sa_db_unlock`
- `sa_db_update_u64_add`

Logical ERP type helper calls:

- `sa_db_decimal_from_parts`
- `sa_db_decimal_to_parts`
- `sa_db_date_from_ymd`
- `sa_db_date_to_ymd`
- `sa_db_timestamp_ms_from_parts`
- `sa_db_timestamp_ms_to_parts`
- `sa_db_timestamp_us_from_parts`
- `sa_db_timestamp_us_to_parts`
- `sa_db_bool_encode`
- `sa_db_bool_decode`
- `sa_db_null_bitmap_required_bytes`
- `sa_db_null_bitmap_clear`
- `sa_db_null_bitmap_set`
- `sa_db_null_bitmap_get`

Read-handle query calls:

- `sa_db_open_read_table`
- `sa_db_close_read_table`
- `sa_db_snapshot_info_handle`
- `sa_db_column_info_handle`
- `sa_db_column_logical_info_handle`
- `sa_db_sum_u64_handle`
- `sa_db_sum_i64_handle`
- `sa_db_stats_rows_u64_handle`
- `sa_db_stats_rows_i64_handle`
- `sa_db_group_sum_i64_by_u64_handle`
- `sa_db_group_rows_sum_i64_by_u64_handle`
- `sa_db_group_sum_i64_by_u64_sorted_handle`
- `sa_db_group_rows_sum_i64_by_u64_sorted_handle`
- `sa_db_group_stats_i64_by_u64_handle`
- `sa_db_group_rows_stats_i64_by_u64_handle`
- `sa_db_group_stats_i64_by_u64_sorted_handle`
- `sa_db_group_rows_stats_i64_by_u64_sorted_handle`
- `sa_db_count_u64_eq_handle`
- `sa_db_count_dict_eq_handle`
- `sa_db_count_u64_cmp_handle`
- `sa_db_count_i64_cmp_handle`
- `sa_db_count_u32_cmp_handle`
- `sa_db_count_i32_cmp_handle`
- `sa_db_count_bool_handle`
- `sa_db_find_u64_handle`
- `sa_db_find_i64_handle`
- `sa_db_find_u32_handle`
- `sa_db_find_i32_handle`
- `sa_db_find_bool_handle`
- `sa_db_find_u64_pair_handle`
- `sa_db_find_u64_i64_pair_handle`
- `sa_db_range_u64_handle`
- `sa_db_range_i64_handle`
- `sa_db_range_u32_handle`
- `sa_db_range_i32_handle`
- `sa_db_range_u64_null_bitmap_handle`
- `sa_db_range_i64_null_bitmap_handle`
- `sa_db_range_decimal_i64_handle`
- `sa_db_range_decimal_i64_null_bitmap_handle`
- `sa_db_range_date_handle`
- `sa_db_range_date_null_bitmap_handle`
- `sa_db_range_timestamp_ms_handle`
- `sa_db_range_timestamp_ms_null_bitmap_handle`
- `sa_db_range_timestamp_us_handle`
- `sa_db_range_timestamp_us_null_bitmap_handle`
- `sa_db_range_u64_pair_handle`
- `sa_db_range_u64_i64_pair_handle`
- `sa_db_range_u64_date_pair_handle`
- `sa_db_range_u64_timestamp_ms_pair_handle`
- `sa_db_range_u64_timestamp_us_pair_handle`
- `sa_db_filter_u64_pair_key1_handle`
- `sa_db_filter_u64_i64_pair_key1_handle`
- `sa_db_filter_bool_handle`
- `sa_db_filter_dict_eq_handle`
- `sa_db_filter_rows_u64_range_handle`
- `sa_db_filter_rows_i64_range_handle`
- `sa_db_filter_rows_dict_eq_handle`
- `sa_db_plan_u64_i64_ranges_handle`
- `sa_db_plan_u64_u64_ranges_handle`
- `sa_db_plan_i64_i64_ranges_handle`
- `sa_db_plan_u64_dict_eq_handle`
- `sa_db_plan_i64_dict_eq_handle`
- `sa_db_plan_u64_blob_eq_handle`
- `sa_db_plan_i64_blob_eq_handle`
- `sa_db_plan_u64_i64_blob_eq_handle`
- `sa_db_plan_u64_i64_dict_eq_handle`
- `sa_db_plan_u64_i64_bool_handle`
- `sa_db_plan_u64_i64_i64_ranges_handle`
- `sa_db_plan_u64_date_decimal_i64_handle`
- `sa_db_filter_rows_f32_range_handle`
- `sa_db_filter_rows_f64_range_handle`
- `sa_db_filter_rows_u32_range_handle`
- `sa_db_filter_rows_i32_range_handle`
- `sa_db_filter_rows_u8_range_handle`
- `sa_db_filter_rows_i8_range_handle`
- `sa_db_filter_rows_u16_range_handle`
- `sa_db_filter_rows_i16_range_handle`
- `sa_db_filter_rows_decimal_i64_range_handle`
- `sa_db_filter_rows_date_range_handle`
- `sa_db_filter_rows_timestamp_ms_range_handle`
- `sa_db_filter_rows_timestamp_us_range_handle`
- `sa_db_filter_rows_bool_handle`
- `sa_db_intersect_rows_handle`
- `sa_db_union_rows_handle`
- `sa_db_except_rows_handle`
- `sa_db_sort_rows_u64_handle`
- `sa_db_sort_rows_i64_handle`
- `sa_db_sort_rows_f32_handle`
- `sa_db_sort_rows_f64_handle`
- `sa_db_sort_rows_u32_handle`
- `sa_db_sort_rows_i32_handle`
- `sa_db_sort_rows_u8_handle`
- `sa_db_sort_rows_i8_handle`
- `sa_db_sort_rows_u16_handle`
- `sa_db_sort_rows_i16_handle`
- `sa_db_filter_blob_eq_handle`
- `sa_db_filter_blob_contains_handle`
- `sa_db_filter_blob_token_handle`
- `sa_db_filter_blob_prefix_handle`
- `sa_db_filter_rows_blob_eq_handle`
- `sa_db_filter_rows_blob_contains_handle`
- `sa_db_filter_rows_blob_token_handle`
- `sa_db_filter_rows_blob_prefix_handle`
- `sa_db_get_u64_handle`
- `sa_db_get_i64_handle`
- `sa_db_get_u32_handle`
- `sa_db_get_i32_handle`
- `sa_db_get_bool_handle`
- `sa_db_project_rows_handle`
- `sa_db_get_row_handle`
- `sa_db_get_row_u64_key_handle`
- `sa_db_get_row_i64_key_handle`
- `sa_db_get_row_u32_key_handle`
- `sa_db_get_row_i32_key_handle`
- `sa_db_get_row_u8_key_handle`
- `sa_db_get_row_i8_key_handle`
- `sa_db_get_row_u16_key_handle`
- `sa_db_get_row_i16_key_handle`
- `sa_db_get_row_u64_pair_key_handle`
- `sa_db_get_row_u64_i64_pair_key_handle`
- `sa_db_get_row_blob_eq_key_handle`
- `sa_db_min_u64_handle`
- `sa_db_max_u64_handle`
- `sa_db_min_i64_handle`
- `sa_db_max_i64_handle`
- `sa_db_min_u32_handle`
- `sa_db_max_u32_handle`
- `sa_db_min_i32_handle`
- `sa_db_max_i32_handle`

Public status constants include `SA_DB_ERR_CONSTRAINT` for writes that violate
unique indexes.

Removed calls:

- `sa_db_sum_u64`
- `sa_db_count_u64_eq`
- `DB_SUM_U64`
- `DB_COUNT_U64_EQ`

The `sal` facade exposes matching macros such as `DB_OPEN_READ_TABLE`,
`DB_SNAPSHOT_INFO_HANDLE`, `DB_COLUMN_INFO_HANDLE`, `DB_SUM_U64_HANDLE`,
`DB_SUM_I64_HANDLE`, `DB_STATS_ROWS_U64_HANDLE`, `DB_STATS_ROWS_I64_HANDLE`,
`DB_GROUP_SUM_I64_BY_U64_HANDLE`, `DB_GROUP_ROWS_SUM_I64_BY_U64_HANDLE`,
`DB_GROUP_SUM_I64_BY_U64_SORTED_HANDLE`, `DB_GROUP_ROWS_SUM_I64_BY_U64_SORTED_HANDLE`,
`DB_COUNT_U64_CMP_HANDLE`, `DB_COUNT_I64_CMP_HANDLE`, `DB_COUNT_U32_CMP_HANDLE`,
`DB_COUNT_I32_CMP_HANDLE`, `DB_COUNT_U8_CMP_HANDLE`, `DB_COUNT_I8_CMP_HANDLE`,
`DB_COUNT_U16_CMP_HANDLE`, `DB_COUNT_I16_CMP_HANDLE`, `DB_COUNT_F32_CMP_HANDLE`,
`DB_COUNT_F64_CMP_HANDLE`, `DB_COUNT_BOOL_HANDLE`, `DB_FIND_U64_HANDLE`,
`DB_FIND_I64_HANDLE`, `DB_FIND_U32_HANDLE`, `DB_FIND_I32_HANDLE`, `DB_FIND_U8_HANDLE`,
`DB_FIND_I8_HANDLE`, `DB_FIND_U16_HANDLE`, `DB_FIND_I16_HANDLE`, `DB_FIND_F32_HANDLE`,
`DB_FIND_F64_HANDLE`,
`DB_FIND_BOOL_HANDLE`, `DB_FIND_U64_PAIR_HANDLE`, `DB_FIND_U64_I64_PAIR_HANDLE`, `DB_RANGE_U64_HANDLE`,
`DB_RANGE_I64_HANDLE`, `DB_RANGE_U32_HANDLE`, `DB_RANGE_I32_HANDLE`,
`DB_RANGE_U8_HANDLE`, `DB_RANGE_I8_HANDLE`, `DB_RANGE_U16_HANDLE`,
`DB_RANGE_I16_HANDLE`, `DB_RANGE_F32_HANDLE`, `DB_RANGE_F64_HANDLE`,
`DB_RANGE_U64_PAIR_HANDLE`, `DB_RANGE_U64_I64_PAIR_HANDLE`,
`DB_RANGE_U64_DATE_PAIR_HANDLE`, `DB_RANGE_U64_TIMESTAMP_MS_PAIR_HANDLE`,
`DB_RANGE_U64_TIMESTAMP_US_PAIR_HANDLE`,
`DB_FILTER_U64_PAIR_KEY1_HANDLE`, `DB_FILTER_U64_I64_PAIR_KEY1_HANDLE`,
`DB_FILTER_BOOL_HANDLE`, `DB_FILTER_ROWS_U64_RANGE_HANDLE`,
`DB_FILTER_ROWS_I64_RANGE_HANDLE`, `DB_PLAN_U64_I64_RANGES_HANDLE`,
`DB_PLAN_U64_U64_RANGES_HANDLE`, `DB_PLAN_I64_I64_RANGES_HANDLE`,
`DB_PLAN_U64_BLOB_EQ_HANDLE`, `DB_PLAN_I64_BLOB_EQ_HANDLE`,
`DB_PLAN_U64_I64_BLOB_EQ_HANDLE`,
`DB_PLAN_U64_I64_BOOL_HANDLE`,
`DB_PLAN_U64_I64_I64_RANGES_HANDLE`,
`DB_FILTER_ROWS_U32_RANGE_HANDLE`,
`DB_FILTER_ROWS_I32_RANGE_HANDLE`, `DB_FILTER_ROWS_U8_RANGE_HANDLE`,
`DB_FILTER_ROWS_I8_RANGE_HANDLE`, `DB_FILTER_ROWS_U16_RANGE_HANDLE`,
`DB_FILTER_ROWS_I16_RANGE_HANDLE`, `DB_FILTER_ROWS_DECIMAL_I64_RANGE_HANDLE`,
`DB_FILTER_ROWS_DATE_RANGE_HANDLE`, `DB_FILTER_ROWS_TIMESTAMP_MS_RANGE_HANDLE`,
`DB_FILTER_ROWS_TIMESTAMP_US_RANGE_HANDLE`, `DB_FILTER_ROWS_BOOL_HANDLE`,
`DB_INTERSECT_ROWS_HANDLE`, `DB_UNION_ROWS_HANDLE`, `DB_EXCEPT_ROWS_HANDLE`,
`DB_SORT_ROWS_U64_HANDLE`, `DB_SORT_ROWS_I64_HANDLE`,
`DB_SORT_ROWS_U32_HANDLE`, `DB_SORT_ROWS_I32_HANDLE`,
`DB_SORT_ROWS_U8_HANDLE`, `DB_SORT_ROWS_I8_HANDLE`,
`DB_SORT_ROWS_U16_HANDLE`, `DB_SORT_ROWS_I16_HANDLE`,
`DB_FILTER_BLOB_EQ_HANDLE`, `DB_FILTER_BLOB_CONTAINS_HANDLE`,
`DB_FILTER_BLOB_TOKEN_HANDLE`, `DB_FILTER_BLOB_PREFIX_HANDLE`,
`DB_FILTER_ROWS_BLOB_EQ_HANDLE`, `DB_FILTER_ROWS_BLOB_CONTAINS_HANDLE`,
`DB_FILTER_ROWS_BLOB_TOKEN_HANDLE`, `DB_FILTER_ROWS_BLOB_PREFIX_HANDLE`, `DB_GET_U64_HANDLE`,
`DB_GET_I64_HANDLE`, `DB_GET_U32_HANDLE`, `DB_GET_I32_HANDLE`, `DB_GET_U8_HANDLE`,
`DB_GET_I8_HANDLE`, `DB_GET_U16_HANDLE`, `DB_GET_I16_HANDLE`, `DB_GET_F32_HANDLE`,
`DB_GET_F64_HANDLE`,
`DB_GET_BOOL_HANDLE`, `DB_PROJECT_ROWS_HANDLE`, `DB_GET_ROW_HANDLE`,
`DB_GET_ROW_U64_KEY_HANDLE`, `DB_GET_ROW_I64_KEY_HANDLE`,
`DB_GET_ROW_U32_KEY_HANDLE`, `DB_GET_ROW_I32_KEY_HANDLE`,
`DB_GET_ROW_U8_KEY_HANDLE`, `DB_GET_ROW_I8_KEY_HANDLE`,
`DB_GET_ROW_U16_KEY_HANDLE`, `DB_GET_ROW_I16_KEY_HANDLE`,
`DB_GET_ROW_U64_PAIR_KEY_HANDLE`, `DB_GET_ROW_U64_I64_PAIR_KEY_HANDLE`,
`DB_GET_ROW_BLOB_EQ_KEY_HANDLE`,
`DB_INGEST_COLUMNS`, `DB_INSERT_ROW`,
`DB_UPSERT_ROW_U64_KEY`, `DB_UPDATE_ROW_U64_KEY`,
`DB_UPSERT_ROW_U32_KEY`, `DB_UPDATE_ROW_U32_KEY`,
`DB_UPSERT_ROW_I32_KEY`, `DB_UPDATE_ROW_I32_KEY`,
`DB_UPSERT_ROW_U8_KEY`, `DB_UPDATE_ROW_U8_KEY`,
`DB_UPSERT_ROW_I8_KEY`, `DB_UPDATE_ROW_I8_KEY`,
`DB_UPSERT_ROW_U16_KEY`, `DB_UPDATE_ROW_U16_KEY`,
`DB_UPSERT_ROW_I16_KEY`, `DB_UPDATE_ROW_I16_KEY`,
`DB_UPSERT_ROW_I64_KEY`, `DB_UPDATE_ROW_I64_KEY`,
`DB_UPSERT_ROW_U64_PAIR_KEY`, `DB_UPDATE_ROW_U64_PAIR_KEY`,
`DB_UPSERT_ROW_U64_I64_PAIR_KEY`, `DB_UPDATE_ROW_U64_I64_PAIR_KEY`,
`DB_TX_BEGIN`, `DB_TX_INSERT_ROW`,
`DB_TX_DICT_INTERN`, `DB_TX_BLOB_PUT`,
`DB_TX_UPSERT_ROW_U64_KEY`, `DB_TX_UPDATE_ROW_U64_KEY`, `DB_TX_DELETE_U64_KEY`,
`DB_TX_UPSERT_ROW_U32_KEY`, `DB_TX_UPDATE_ROW_U32_KEY`, `DB_TX_DELETE_U32_KEY`,
`DB_TX_UPSERT_ROW_I32_KEY`, `DB_TX_UPDATE_ROW_I32_KEY`, `DB_TX_DELETE_I32_KEY`,
`DB_TX_UPSERT_ROW_U8_KEY`, `DB_TX_UPDATE_ROW_U8_KEY`, `DB_TX_DELETE_U8_KEY`,
`DB_TX_UPSERT_ROW_I8_KEY`, `DB_TX_UPDATE_ROW_I8_KEY`, `DB_TX_DELETE_I8_KEY`,
`DB_TX_UPSERT_ROW_U16_KEY`, `DB_TX_UPDATE_ROW_U16_KEY`, `DB_TX_DELETE_U16_KEY`,
`DB_TX_UPSERT_ROW_I16_KEY`, `DB_TX_UPDATE_ROW_I16_KEY`, `DB_TX_DELETE_I16_KEY`,
`DB_TX_UPSERT_ROW_I64_KEY`, `DB_TX_UPDATE_ROW_I64_KEY`, `DB_TX_DELETE_I64_KEY`,
`DB_TX_UPSERT_ROW_U64_PAIR_KEY`, `DB_TX_UPDATE_ROW_U64_PAIR_KEY`,
`DB_TX_DELETE_U64_PAIR_KEY`, `DB_TX_UPSERT_ROW_U64_I64_PAIR_KEY`,
`DB_TX_UPDATE_ROW_U64_I64_PAIR_KEY`, `DB_TX_DELETE_U64_I64_PAIR_KEY`,
`DB_TX_COMMIT`, `DB_TX_ROLLBACK`,
`DB_CREATE_U64_INDEX`, `DB_CREATE_I64_INDEX`,
`DB_CREATE_U32_INDEX`, `DB_CREATE_I32_INDEX`, `DB_CREATE_U8_INDEX`,
`DB_CREATE_I8_INDEX`, `DB_CREATE_U16_INDEX`, `DB_CREATE_I16_INDEX`, `DB_CREATE_F32_INDEX`,
`DB_CREATE_F64_INDEX`, `DB_CREATE_U64_PAIR_INDEX`, `DB_CREATE_U64_I64_PAIR_INDEX`,
`DB_CREATE_BLOB_EQ_INDEX`, `DB_CREATE_BLOB_TOKEN_INDEX`,
`DB_CREATE_BLOB_PREFIX_INDEX`, `DB_CREATE_BLOB_CONTAINS_INDEX`,
`DB_DICT_INTERN`, `DB_DICT_LOOKUP`, `DB_DICT_VALUE_LEN`,
`DB_DICT_VALUE_COPY`, `DB_DICT_LOOKUP_HANDLE`, `DB_DICT_VALUE_LEN_HANDLE`,
`DB_DICT_VALUE_COPY_HANDLE`, `DB_BLOB_PUT`, `DB_BLOB_VALUE_LEN`,
`DB_BLOB_VALUE_COPY`, `DB_BLOB_VALUE_LEN_HANDLE`,
`DB_BLOB_VALUE_COPY_HANDLE`, `DB_FILTER_BLOB_EQ_HANDLE`,
`DB_FILTER_BLOB_CONTAINS_HANDLE`, `DB_FILTER_BLOB_TOKEN_HANDLE`,
`DB_FILTER_BLOB_PREFIX_HANDLE`,
`DB_DELETE_U64_KEY`, `DB_DELETE_U32_KEY`, `DB_DELETE_I32_KEY`,
`DB_DELETE_U8_KEY`, `DB_DELETE_I8_KEY`, `DB_DELETE_U16_KEY`, `DB_DELETE_I16_KEY`,
`DB_DELETE_I64_KEY`, `DB_DELETE_U64_PAIR_KEY`,
`DB_DELETE_U64_I64_PAIR_KEY`,
`DB_MIN_U64_HANDLE`, `DB_MAX_U64_HANDLE`,
`DB_MIN_I64_HANDLE`, `DB_MAX_I64_HANDLE`, `DB_MIN_U8_HANDLE`, `DB_MAX_U8_HANDLE`,
`DB_MIN_I8_HANDLE`, `DB_MAX_I8_HANDLE`, `DB_MIN_U16_HANDLE`, `DB_MAX_U16_HANDLE`,
`DB_MIN_I16_HANDLE`, `DB_MAX_I16_HANDLE`, `DB_MIN_F32_HANDLE`, `DB_MAX_F32_HANDLE`,
`DB_MIN_F64_HANDLE`, `DB_MAX_F64_HANDLE`, `DB_SNAPSHOT`, `DB_RESTORE`, and
`DB_RECOVER`.

## Query Model

Read queries now use snapshots:

1. `sa_db_open_read_table` opens a read handle and copies immutable column bytes
   into a read snapshot.
2. `sa_db_snapshot_info_handle`, `sa_db_column_info_handle`, and
   `sa_db_column_logical_info_handle` expose snapshot row count, column count,
   row width, epoch, column stride, primitive type code, metadata string lengths,
   logical type, logical scale, and nullable marker without requiring callers to
   parse JSON meta.
   `sa_db_export_null_bitmap_handle` / `DB_EXPORT_NULL_BITMAP_HANDLE` exports a
   logical `u8 null_bitmap` column from the snapshot into the same packed bitmap
   layout used by the nullable range/filter helper APIs, so persisted null state
   can be reused directly by SA query code.
3. `*_handle` query functions scan the in-memory snapshot; `find_u64` and
   `count_u64_cmp` use a persisted sorted `u64 -> row` index when one exists for
   the column. Signed `i64` columns now have the same point/range/count/min/max
   read-handle surface through a persisted signed-order index, which is suitable
   for ERP amount cents, balances, and timestamp encodings. Compact `u8`, `i8`,
   `u16`, `i16`, `u32`, and `i32` columns now also support persisted indexes plus count/find/range/get
   and min/max helpers, which fits status codes, warehouse IDs, line numbers,
   small foreign keys, and signed adjustment fields without forcing 8-byte
   storage. Finite `f32` and `f64` columns also support persisted indexes plus
   count/find/range/get/min/max for weights, rates, dimensions, and other
   non-money measurements; NaN and +/-Inf are rejected because their ordering is
   not stable business data. A persisted
   `u64_pair -> row` index supports ERP composite keys such as
   `(order_id, line_no)`, `(product_id, warehouse_id)`, or
   `(customer_id, date_code)` with point lookup, fixed-first-key list pagination,
   and fixed-first-key range pagination over the second key. A persisted
   `u64_i64_pair -> row` index keeps the same lookup and pagination contract for
   `(u64, i64)` tuples, with signed ordering on the second key. It is intended
   for ERP filters such as `(customer_id, order_day)`, `(status_id, due_day)`,
   or `(product_id, posted_day)` where date/time/amount encodings are signed
   `i64`. A persisted `blob_eq -> row` index accelerates
   exact filters over `blob_handle` columns for high-frequency text/blob equality
   predicates, while persisted `blob_token -> row` and `blob_prefix -> row`
   indexes accelerate ASCII token and token-prefix searches over ERP text/blob
   fields. Blob index paths keep collision checks against the snapshot blob
   bytes.
   Logical `bool` columns expose count, first
   match, row-list filtering, and get helpers over `u8`/`i1` or `u64` `0/1`
   encodings. `project_rows_handle` copies only selected columns for a batch of
   row indices. `get_row_handle` copies a full fixed-width row by snapshot row
   index, while `get_row_*_key_handle` requires a matching unique integer,
   composite, or text/blob key index (`u64`, `i64`, `u32`, `i32`, `u8`, `i8`,
   `u16`, `i16`, `(u64, u64)`, `(u64, i64)`, or unique `blob_eq`) and copies
   the matching row into the caller's row buffer.
4. `sa_db_close_read_table` releases the snapshot.

Primitive type codes exported through `db.sal` match the schema compiler enum:
`SA_DB_TYPE_I1`, `I8`, `I16`, `I32`, `I64`, `U8`, `U16`, `U32`, `U64`, `F32`,
`F64`, `PTR`, `BLOB_HANDLE`, and `V128`. ERP code can keep storage primitive
while using the logical helper ABI for common business types: decimal/money is
encoded as scaled `i64`, date as epoch days, timestamp as epoch milliseconds or
microseconds, boolean as normalized `0/1`, and nullable fields as a sidecar null
bitmap. Logical bool queries require a column annotation such as `// u8 bool` or
`// u64 bool`, reject non-`0/1` stored values, and return filtered rows in
snapshot row order. These helpers deliberately do not introduce a new physical
format yet, so existing integer and finite-float indexes, range reads,
projections, and fixed-width row buffers remain the query surface.
Schema comments can now carry logical metadata after the primitive type and
before an optional `:` description, for example `// i64 decimal(2) nullable`,
`// i64 date`, `// i64 timestamp_ms`, `// i64 timestamp_us`, or `// u8 bool`.
These annotations are stored in table metadata and surfaced through
`sa_db_column_logical_info_handle` / `DB_COLUMN_LOGICAL_INFO_HANDLE` using the
`SA_DB_LOGICAL_*` constants, so SA ERP code can inspect column semantics at
runtime while keeping the on-disk bytes primitive and fixed-width. Existing
schemas without annotations keep `SA_DB_LOGICAL_NONE`, scale `0`, and nullable
`0`.

Low-cardinality strings are supported through table-level dictionaries rather
than variable-width string columns. `sa_db_dict_intern` / `DB_DICT_INTERN` maps a
non-empty byte string such as `active`, `paid`, `warehouse_a`, or `invoice` to a
stable 1-based `u64` ID inside a named dictionary; ID `0` is reserved for caller
semantics such as null/unknown. Repeated intern returns the existing ID without
advancing the table epoch. `sa_db_dict_lookup` finds an existing ID,
`sa_db_dict_value_len` returns the byte length for an ID, and
`sa_db_dict_value_copy` copies the stored bytes into the caller buffer. ERP rows
store the returned ID in a normal `u64` column, so status/category/type fields can
reuse the existing `u64` indexes, range reads, projections, and row APIs.
`sa_db_tx_dict_intern` / `DB_TX_DICT_INTERN` is the transaction-scoped form for
interning dictionary values inside the same single-table transaction as row
inserts, updates, deletes, or blob writes. A transaction-created value is not
visible to direct lookups or read handles until commit, and rollback leaves the
active dictionary unchanged.
For read-heavy ERP list rendering, prefer the read-handle variants
`sa_db_dict_lookup_handle`, `sa_db_dict_value_len_handle`, and
`sa_db_dict_value_copy_handle` after `sa_db_open_read_table`; the dictionary bytes
are already part of the immutable snapshot, so repeated lookups do not re-open the
table metadata or dictionary artifact.
When a `u64` row column stores dictionary IDs, read handles can query by the
dictionary value directly instead of requiring a separate lookup in SA code.
`sa_db_count_dict_eq_handle` / `DB_COUNT_DICT_EQ_HANDLE` counts rows whose
dictionary-backed `u64` column resolves to one exact value. `sa_db_filter_dict_eq_handle`
/ `DB_FILTER_DICT_EQ_HANDLE` returns matching row ids directly, and
`sa_db_filter_rows_dict_eq_handle` / `DB_FILTER_ROWS_DICT_EQ_HANDLE` applies the
same exact dictionary-value predicate to an existing candidate row-id list while
preserving candidate order. For common ERP list shapes, `sa_db_plan_u64_dict_eq_handle`
/ `DB_PLAN_U64_DICT_EQ_HANDLE`, `sa_db_plan_i64_dict_eq_handle` /
`DB_PLAN_I64_DICT_EQ_HANDLE`, and `sa_db_plan_u64_i64_dict_eq_handle` /
`DB_PLAN_U64_I64_DICT_EQ_HANDLE` combine one or two numeric range predicates with
one exact dictionary-value predicate and choose the smallest candidate side first.
These APIs take both `dict_name` and the stored `value` bytes because the current
schema metadata does not yet bind a column to one dictionary namespace.

General variable-width bytes and text use table-level blob stores plus a
fixed-width `blob_handle` row column. `sa_db_blob_put` / `DB_BLOB_PUT` appends a
value to a named store and returns a stable 1-based handle; handle `0` remains
available for caller null/missing semantics. Empty values are valid, and repeated
equal byte strings intentionally receive distinct handles because this path is
for varchar/blob data rather than low-cardinality deduplication. Use
`sa_db_blob_value_len` / `DB_BLOB_VALUE_LEN` and `sa_db_blob_value_copy` /
`DB_BLOB_VALUE_COPY` to decode current table state. After
`sa_db_open_read_table`, use `sa_db_blob_value_len_handle` /
`DB_BLOB_VALUE_LEN_HANDLE` and `sa_db_blob_value_copy_handle` /
`DB_BLOB_VALUE_COPY_HANDLE`; blob bytes are part of the immutable snapshot, so
new blob writes are not visible to an already-open read handle. Read handles also
provide first-pass text/blob filtering through `sa_db_filter_blob_eq_handle` /
`DB_FILTER_BLOB_EQ_HANDLE` and `sa_db_filter_blob_contains_handle` /
`DB_FILTER_BLOB_CONTAINS_HANDLE`. `sa_db_create_blob_eq_index` /
`DB_CREATE_BLOB_EQ_INDEX` builds a persisted exact-match secondary index for one
`blob_handle` column and one named store; `DB_FILTER_BLOB_EQ_HANDLE` uses it
automatically when present, then confirms candidate rows against the immutable
blob bytes so hash collisions cannot leak false matches. Without the index, exact
filtering falls back to the previous snapshot scan. When the exact index is
unique, `sa_db_get_row_blob_eq_key_handle` / `DB_GET_ROW_BLOB_EQ_KEY_HANDLE`
fetches the full fixed-width row for one exact text/blob value, which covers ERP
lookups by document number, customer/vendor code, SKU, or external ID stored in a
`blob_handle` column. The matching write path is
`sa_db_upsert_row_blob_eq_key` / `DB_UPSERT_ROW_BLOB_EQ_KEY`,
`sa_db_update_row_blob_eq_key` / `DB_UPDATE_ROW_BLOB_EQ_KEY`, and
`sa_db_delete_blob_eq_key` / `DB_DELETE_BLOB_EQ_KEY`, plus transaction variants.
Those calls require the row's `blob_handle` to reference bytes equal to the key
argument and still confirm indexed hash candidates against real blob bytes.
`sa_db_create_blob_token_index`
/ `DB_CREATE_BLOB_TOKEN_INDEX` builds a persisted token index for ASCII
letters/digits/underscore tokens. `sa_db_filter_blob_token_handle` /
`DB_FILTER_BLOB_TOKEN_HANDLE` is case-insensitive, returns only rows whose blob
contains the full token, and confirms candidates against snapshot blob bytes so
hash collisions cannot leak false matches. `sa_db_create_blob_prefix_index` /
`DB_CREATE_BLOB_PREFIX_INDEX` builds a persisted token-prefix index for the same
ASCII letters/digits/underscore token model. `sa_db_filter_blob_prefix_handle` /
`DB_FILTER_BLOB_PREFIX_HANDLE` is case-insensitive, matches prefixes at token
starts rather than arbitrary substrings, accepts prefixes up to 64 bytes, and
confirms hash candidates against the snapshot blob bytes. `sa_db_create_blob_contains_index`
/ `DB_CREATE_BLOB_CONTAINS_INDEX` builds a persisted byte-level trigram candidate
index for substring contains filters. `sa_db_filter_blob_contains_handle` /
`DB_FILTER_BLOB_CONTAINS_HANDLE` uses it automatically for needles of at least 3
bytes, picks the most selective trigram candidate from the query, then confirms
the full substring against snapshot blob bytes; empty and 1-2 byte needles keep
the scan path to preserve exact contains semantics. Blob filters return row indices with the same
`offset`/`limit`/`total` contract as other list
queries, and let ERP screens filter notes, addresses, descriptions, or external
payload keys before projecting rows.
`sa_db_filter_rows_blob_eq_handle`, `sa_db_filter_rows_blob_contains_handle`,
`sa_db_filter_rows_blob_token_handle`, and `sa_db_filter_rows_blob_prefix_handle`
apply the same text/blob predicates to an existing candidate row-id list. They
preserve the candidate list order and pagination contract, so callers can run a
selective customer/date/status index first, then narrow notes, addresses,
descriptions, SKUs, or external keys without materializing text values in SA.

`sa_db_range_u64_handle` / `DB_RANGE_U64_HANDLE` returns row indices for an
inclusive `[min, max]` range over an indexed `u64` column. It is designed for ERP
list pages and key/date/order-number windows: callers pass `offset`, `limit`, and
a `u64` row-index buffer; the API returns `total` matches and `written` row
indices in index order. The target column must have a persisted `u64` index, so
range pagination uses binary-search bounds instead of a full scan.
Use `sa_db_get_row_handle` / `DB_GET_ROW_HANDLE` to materialize any returned row
index into a fixed-width row buffer. Use `DB_GET_ROW_*_KEY_HANDLE` when an ERP
form needs a direct full-row fetch by a unique typed primary key, unique
composite child-row key, or unique text/blob key without a separate `find` call.
`sa_db_range_i64_handle` / `DB_RANGE_I64_HANDLE` behaves the same for indexed
`i64` columns, but uses signed ordering so negative values sort before zero and
positive values.
`sa_db_range_u8_handle` / `DB_RANGE_U8_HANDLE`, `sa_db_range_i8_handle` /
`DB_RANGE_I8_HANDLE`, `sa_db_range_u16_handle` / `DB_RANGE_U16_HANDLE`,
`sa_db_range_i16_handle` / `DB_RANGE_I16_HANDLE`, `sa_db_range_u32_handle` /
`DB_RANGE_U32_HANDLE`, and `sa_db_range_i32_handle` / `DB_RANGE_I32_HANDLE`
provide the same indexed pagination for compact 1-, 2-, and 4-byte columns, with signed types using signed ordering. These
are intended for ERP status codes, warehouse IDs, line numbers, compact foreign
keys, and signed adjustment fields.
`sa_db_range_f32_handle` / `DB_RANGE_F32_HANDLE` and `sa_db_range_f64_handle` /
`DB_RANGE_F64_HANDLE` provide the same indexed pagination for finite float
columns; use scaled `i64` decimal helpers for money where exact arithmetic is
required.
`sa_db_range_u64_null_bitmap_handle` / `DB_RANGE_U64_NULL_BITMAP_HANDLE` and
`sa_db_range_i64_null_bitmap_handle` / `DB_RANGE_I64_NULL_BITMAP_HANDLE` add a
sidecar null-bitmap predicate before pagination. The returned `total`, `offset`,
and `limit` are computed after filtering, so list pages do not lose rows by
filtering only the current page in SA code.
`sa_db_range_decimal_i64_handle` / `DB_RANGE_DECIMAL_I64_HANDLE` and
`sa_db_range_decimal_i64_null_bitmap_handle` /
`DB_RANGE_DECIMAL_I64_NULL_BITMAP_HANDLE` accept decimal parts and scale, encode
them as signed scaled `i64`, and then use the signed index. `sa_db_range_date_handle`
/ `DB_RANGE_DATE_HANDLE` and `sa_db_range_date_null_bitmap_handle` /
`DB_RANGE_DATE_NULL_BITMAP_HANDLE` do the same for Y-M-D date ranges encoded as
epoch days. `sa_db_range_timestamp_ms_handle` / `DB_RANGE_TIMESTAMP_MS_HANDLE`,
`sa_db_range_timestamp_ms_null_bitmap_handle` /
`DB_RANGE_TIMESTAMP_MS_NULL_BITMAP_HANDLE`, `sa_db_range_timestamp_us_handle` /
`DB_RANGE_TIMESTAMP_US_HANDLE`, and `sa_db_range_timestamp_us_null_bitmap_handle`
/ `DB_RANGE_TIMESTAMP_US_NULL_BITMAP_HANDLE` do the same for timestamp columns
encoded as epoch milliseconds or microseconds from `(epoch_day, subday_units)`.
Invalid dates, decimal parts, or subday values outside the selected unit day
return `SA_DB_ERR_INVALID_ARGUMENT` without running the range query.
`sa_db_create_u64_pair_index` / `DB_CREATE_U64_PAIR_INDEX` builds a persisted
composite index over two `u64` columns. `unique=1` enforces uniqueness of the
whole `(key1, key2)` tuple. `sa_db_find_u64_pair_handle` /
`DB_FIND_U64_PAIR_HANDLE` finds one exact tuple. `sa_db_range_u64_pair_handle` /
`DB_RANGE_U64_PAIR_HANDLE` returns row indices for one fixed first key and an
inclusive second-key range, with the same `offset`/`limit` pagination contract as
single-column range reads. `sa_db_filter_u64_pair_key1_handle` /
`DB_FILTER_U64_PAIR_KEY1_HANDLE` lists every row matching a fixed first key with
the same pagination contract, which covers ERP child-row screens such as all
lines for one order or all stock movements for one product. When the pair index
is unique, `sa_db_get_row_u64_pair_key_handle` /
`DB_GET_ROW_U64_PAIR_KEY_HANDLE` fetches the full fixed-width row for one exact
tuple.
`sa_db_create_u64_i64_pair_index` / `DB_CREATE_U64_I64_PAIR_INDEX` provides the
same persisted composite index shape for a `u64` first column and signed `i64`
second column. `sa_db_find_u64_i64_pair_handle` /
`DB_FIND_U64_I64_PAIR_HANDLE` finds one exact tuple,
`sa_db_range_u64_i64_pair_handle` / `DB_RANGE_U64_I64_PAIR_HANDLE` pages one
fixed first key over an inclusive signed second-key range, and
`sa_db_range_u64_date_pair_handle` / `DB_RANGE_U64_DATE_PAIR_HANDLE` accepts the
same range as `(min_year, min_month, min_day)` and `(max_year, max_month,
max_day)`, validates both dates, encodes them to epoch days, and uses the same
`u64_i64_pair` index. `sa_db_range_u64_timestamp_ms_pair_handle` /
`DB_RANGE_U64_TIMESTAMP_MS_PAIR_HANDLE` and
`sa_db_range_u64_timestamp_us_pair_handle` /
`DB_RANGE_U64_TIMESTAMP_US_PAIR_HANDLE` do the same for timestamp second keys:
callers pass `(epoch_day, subday_units)` bounds, the API validates the selected
millisecond or microsecond day unit, encodes to signed epoch time, and uses the
same `u64_i64_pair` index.
`sa_db_filter_u64_i64_pair_key1_handle` /
`DB_FILTER_U64_I64_PAIR_KEY1_HANDLE` lists every row for the fixed first key.
Use this for customer/date, status/due-date, product/posting-date, and other
ERP list filters where the second key is a signed date, timestamp, or amount
encoding. When the pair index is unique, `sa_db_get_row_u64_i64_pair_key_handle`
/ `DB_GET_ROW_U64_I64_PAIR_KEY_HANDLE` fetches the full fixed-width row for one
exact tuple.
Candidate row filters are the first explicit composition layer above these
indexes. `sa_db_filter_rows_u64_range_handle` /
`DB_FILTER_ROWS_U64_RANGE_HANDLE`, `sa_db_filter_rows_i64_range_handle` /
`DB_FILTER_ROWS_I64_RANGE_HANDLE`, finite float variants
`sa_db_filter_rows_f32_range_handle` / `DB_FILTER_ROWS_F32_RANGE_HANDLE` and
`sa_db_filter_rows_f64_range_handle` / `DB_FILTER_ROWS_F64_RANGE_HANDLE`, compact integer variants
`sa_db_filter_rows_u32_range_handle`, `sa_db_filter_rows_i32_range_handle`,
`sa_db_filter_rows_u8_range_handle`, `sa_db_filter_rows_i8_range_handle`,
`sa_db_filter_rows_u16_range_handle`, and
`sa_db_filter_rows_i16_range_handle` with matching `DB_FILTER_ROWS_*_RANGE_HANDLE`
macros, `sa_db_filter_rows_decimal_i64_range_handle` /
`DB_FILTER_ROWS_DECIMAL_I64_RANGE_HANDLE`, `sa_db_filter_rows_date_range_handle`
/ `DB_FILTER_ROWS_DATE_RANGE_HANDLE`,
`sa_db_filter_rows_timestamp_ms_range_handle` /
`DB_FILTER_ROWS_TIMESTAMP_MS_RANGE_HANDLE`,
`sa_db_filter_rows_timestamp_us_range_handle` /
`DB_FILTER_ROWS_TIMESTAMP_US_RANGE_HANDLE`, and
`sa_db_filter_rows_bool_handle` / `DB_FILTER_ROWS_BOOL_HANDLE` take an existing
row-id list, preserve that list's order, apply an additional snapshot column
predicate, and return the same `offset`/`limit`/`total` pagination contract.
Decimal/date/timestamp wrappers validate and encode the logical ERP values before
using the signed integer scan path. SA callers can therefore run an indexed
customer/date or blob/text query first, then narrow the candidate rows by status,
compact warehouse/category/priority codes, amount/date/timestamp range, finite
measurement/rate/weight ranges, or posted/active bool without materializing full rows in SA code. This is a planner
building block rather than a SQL optimizer. For common two-predicate ERP range
shapes, `sa_db_plan_u64_i64_ranges_handle` /
`DB_PLAN_U64_I64_RANGES_HANDLE`, `sa_db_plan_u64_u64_ranges_handle` /
`DB_PLAN_U64_U64_RANGES_HANDLE`, and `sa_db_plan_i64_i64_ranges_handle` /
`DB_PLAN_I64_I64_RANGES_HANDLE`, `sa_db_plan_u64_blob_eq_handle` /
`DB_PLAN_U64_BLOB_EQ_HANDLE`, and `sa_db_plan_i64_blob_eq_handle` /
`DB_PLAN_I64_BLOB_EQ_HANDLE` estimate both indexed predicates, scan the smaller
side first, filter the second predicate inside the plugin, and return
`SaDbPlanInfo` (`written`, `total`, `first_predicate`, `first_total`,
`second_total`) so callers can audit which side was chosen. `first_predicate` is
`1` for the first predicate argument and `2` for the second predicate argument;
ties choose the first side for stable behavior. These cover dictionary/status
codes plus amount/date ranges, two dictionary/status predicates, two signed
amount/date/timestamp ranges, and numeric range plus exact text/blob business
keys such as status/doc-type or due-date/business-code. Broader shapes still use
the explicit building blocks above.
For common ERP three-filter list shapes, `sa_db_plan_u64_i64_blob_eq_handle` /
`DB_PLAN_U64_I64_BLOB_EQ_HANDLE`, `sa_db_plan_u64_i64_bool_handle` /
`DB_PLAN_U64_I64_BOOL_HANDLE`, and `sa_db_plan_u64_i64_i64_ranges_handle` /
`DB_PLAN_U64_I64_I64_RANGES_HANDLE` estimate a `u64` range, an `i64` range, and
either an exact text/blob predicate, a bool predicate, or a second `i64` range,
then order all three by candidate count before filtering. They return
`SaDbPlan3Info` (`written`, `total`, and three `predicate`/`total` pairs).
Predicate ids are `1` for the `u64` range, `2` for the first `i64` range, and
`3` for `blob_eq` in the blob planner, `bool` in the bool planner, or the second
`i64` range in the two-signed-range planner. This covers list pages such as
status + due date plus document type, status + due date plus posted/active flag,
or status + posting date plus amount range without forcing SA code to materialize
and intersect three row-id lists manually.
`sa_db_filter_rows_blob_eq_handle` / `DB_FILTER_ROWS_BLOB_EQ_HANDLE`,
`sa_db_filter_rows_blob_contains_handle` / `DB_FILTER_ROWS_BLOB_CONTAINS_HANDLE`,
`sa_db_filter_rows_blob_token_handle` / `DB_FILTER_ROWS_BLOB_TOKEN_HANDLE`, and
`sa_db_filter_rows_blob_prefix_handle` / `DB_FILTER_ROWS_BLOB_PREFIX_HANDLE`
extend that candidate-row composition model to ERP text/blob fields while
preserving input row order.
`sa_db_intersect_rows_handle` / `DB_INTERSECT_ROWS_HANDLE` is the next planner
building block: callers can run two indexed filters independently, then intersect
their row-id lists inside the plugin while preserving the left list's order and
using the same `offset`/`limit`/`total` pagination contract. This is useful when
two predicates are both selective, for example status/date, text/customer, or
warehouse/product filters, and avoids turning every second predicate into a full
candidate scan.
`sa_db_union_rows_handle` / `DB_UNION_ROWS_HANDLE` and
`sa_db_except_rows_handle` / `DB_EXCEPT_ROWS_HANDLE` complete the same row-list
composition layer for OR and exclusion filters. They validate snapshot row ids,
deduplicate rows, preserve first-seen order with the left list first, and return
the same pagination contract, so ERP list pages can combine indexed predicates
without pulling row ids back into SA code.
`sa_db_stats_rows_u64_handle` / `DB_STATS_ROWS_U64_HANDLE` and
`sa_db_stats_rows_i64_handle` / `DB_STATS_ROWS_I64_HANDLE` aggregate an existing
candidate row list and return `count`, `sum`, `min`, and `max` in one snapshot
pass. Use the signed variant for scaled decimal amounts, date/timestamp extrema,
and signed ERP adjustment totals; an empty candidate list returns zeroed stats.
`sa_db_group_sum_i64_by_u64_handle` / `DB_GROUP_SUM_I64_BY_U64_HANDLE` and
`sa_db_group_rows_sum_i64_by_u64_handle` /
`DB_GROUP_ROWS_SUM_I64_BY_U64_HANDLE` return stable first-seen group pages for a
`u64` business key plus signed `i64` amount column. Each output slot contains the
group key, row count, and signed sum in caller-provided arrays. Use the rows
variant after indexed filters or planners to build ERP totals such as amount by
customer, warehouse, status, or account without copying candidate rows back into
SA code.
`sa_db_group_stats_i64_by_u64_handle` / `DB_GROUP_STATS_I64_BY_U64_HANDLE` and
`sa_db_group_rows_stats_i64_by_u64_handle` /
`DB_GROUP_ROWS_STATS_I64_BY_U64_HANDLE` extend the same grouped page shape with
`min` and `max` arrays for ERP amount extrema and audit-style summaries.
The sorted variants, `sa_db_group_sum_i64_by_u64_sorted_handle` /
`DB_GROUP_SUM_I64_BY_U64_SORTED_HANDLE` and
`sa_db_group_rows_sum_i64_by_u64_sorted_handle` /
`DB_GROUP_ROWS_SUM_I64_BY_U64_SORTED_HANDLE`, return the same group columns after
sorting pages by `sort_by` (`0=key`, `1=count`, `2=sum`, `3=min`, `4=max`) and
`descending` (`0/1`). Groups with equal sort values keep first-seen order, so
Top N customer, warehouse, status, or account reports page deterministically.
`sa_db_sort_rows_u64_handle` / `DB_SORT_ROWS_U64_HANDLE`,
`sa_db_sort_rows_i64_handle` / `DB_SORT_ROWS_I64_HANDLE`, finite float variants
`sa_db_sort_rows_f32_handle` / `DB_SORT_ROWS_F32_HANDLE` and
`sa_db_sort_rows_f64_handle` / `DB_SORT_ROWS_F64_HANDLE`, and compact integer
variants `sa_db_sort_rows_u32_handle`, `sa_db_sort_rows_i32_handle`,
`sa_db_sort_rows_u8_handle`, `sa_db_sort_rows_i8_handle`,
`sa_db_sort_rows_u16_handle`, and `sa_db_sort_rows_i16_handle` with matching
`DB_SORT_ROWS_*_HANDLE` macros sort an existing candidate row list by a snapshot
column, validate that every candidate row is in range, and return a stable
`offset`/`limit` page. Equal sort keys keep the input candidate order, so ERP
list pages stay deterministic after applying filters. Use the signed variants
for scaled decimal amounts, dates, timestamps, signed adjustment fields, and
compact signed business codes.
Use the float variants for finite measurement, rate, discount, weight, and
dimension columns; NaN and infinity are rejected with `SA_DB_ERR_INVALID_FORMAT`.
Use `sa_db_project_rows_handle` / `DB_PROJECT_ROWS_HANDLE` when a list page only
needs selected columns. The output is packed row-major: for each row index in
the input order, bytes for each requested column are appended in the requested
column order. The call returns `written_rows` and `required_bytes`; a too-small
output buffer returns `SA_DB_ERR_CURSOR_OVERFLOW` with `required_bytes` set. An
empty input row list is valid and returns `written_rows=0` and
`required_bytes=0`, so callers can keep one projection path for empty ERP pages.

This makes repeated serial and concurrent reads fast because they no longer
reparse metadata or reread column files for every query. A handle remains a
snapshot: writes made after opening the handle are not visible until a new read
handle is opened.

Writes are protected by an in-process mutex at the SA ABI layer and by a
per-table advisory write lock file (`<table>.write.lock`) in the table layer.
This serializes CLI, qmod, and extern writers across processes for one table;
the lock file is intentionally preserved by table removal so future writers keep
coordinating on the same inode path. Storage writes use file-level atomic
replacement: data is first written to a temporary file in the destination
directory, synced, renamed over the active file, and the parent directory is
synced on Linux when available.
Table commits are selected through an active manifest that points at a versioned
metadata file (`<table>.meta.<epoch>`). Mutating existing column data writes a new
versioned column file and then advances the manifest, so a crash before manifest
replacement leaves the previous epoch readable. Qmod read/write paths use the
same active-manifest protocol as the public table APIs. Segment metadata records
whole-file SHA-256, byte counts, and 64KB block-level SHA-256 lists for newly
written column segment files. Older metadata without block hashes remains
readable, but new segment writes include block hashes and verification checks
them. Single-column integer/float index files, U64-pair and U64/I64-pair index files, blob exact
index files, string dictionary files, and blob store files are also versioned,
hashed, block-hashed, snapshotted, restored, and verified. Indexes are
rebuilt on ingest/update/compact/qmod writes. Verification checks schema hash,
segment hash, segment block hashes, index hash, index block hashes, index
shape/order, dictionary hash, dictionary block hashes, dictionary entry count,
blob store hash, blob store block hashes, blob store entry count, recorded size,
and the expected `rows * column_stride` size. `recover` scans versioned metadata files
and rebuilds the manifest to the highest valid epoch, which covers corrupted or
missing manifest files after an interrupted commit.
Single-table transactions add explicit recovery markers: commit writes
`<table>.tx.<epoch>.pending` before replacement artifacts and writes a verified
`<table>.tx.<epoch>.commit` marker after the versioned transaction metadata is
durable. Recovery ignores pending-only transaction metadata, validates commit
markers against the referenced meta hash/byte count, completes committed
transactions when the active manifest is stale or corrupt, and removes stale
pending markers.

`sa_db_create_u64_index(..., unique=1)` now acts as a real uniqueness
constraint. Creating the unique index rejects existing duplicate values, and
later column ingest, fixed-width row insert, update, compact, and Qmod commit
paths rebuild the persisted index before committing metadata. If duplicate keys
would appear, the write is rejected with `SA_DB_ERR_CONSTRAINT` and the active
manifest remains on the previous table epoch.

`sa_db_create_u64_pair_index(..., unique=1)` applies the same constraint model
to a two-column tuple. This is the first ERP secondary-index shape: order lines
can enforce `(order_id, line_no)`, inventory balances can enforce
`(product_id, warehouse_id)`, and list pages can scan all rows for a fixed first
key over a second-key range without falling back to a full table scan.
`sa_db_create_u64_i64_pair_index(..., unique=1)` applies the same model when the
second key is signed, such as `(customer_id, order_day)` or
`(status_id, due_day)`, and preserves signed ordering for range pagination.

`sa_db_create_blob_eq_index(..., unique=1)` applies the uniqueness model to the
real bytes referenced by one `blob_handle` column in one named store. It rejects
duplicate existing text/blob values, rebuilds on row writes and relevant
`blob_put` calls, and keeps the active manifest on the previous epoch if the
constraint would be violated.

For ERP-style writes, `sa_db_insert_row` / `DB_INSERT_ROW` now accepts one
fixed-width row laid out exactly as the active schema's column strides. The
implementation splits the row into column slices and commits through the same
column ingest path, so the write advances the table epoch and rebuilds any
persisted indexes.

`sa_db_tx_begin` / `DB_TX_BEGIN` starts a single-table write transaction and
returns an opaque handle. `DB_TX_INSERT_ROW`, `DB_TX_DICT_INTERN`, `DB_TX_BLOB_PUT`,
`DB_TX_UPSERT_ROW_U64_KEY`, `DB_TX_UPDATE_ROW_U64_KEY`, and
`DB_TX_DELETE_U64_KEY`, compact-key forms `DB_TX_UPSERT_ROW_U32_KEY`,
`DB_TX_UPDATE_ROW_U32_KEY`, `DB_TX_DELETE_U32_KEY`, `DB_TX_UPSERT_ROW_I32_KEY`,
`DB_TX_UPDATE_ROW_I32_KEY`, `DB_TX_DELETE_I32_KEY`, `DB_TX_UPSERT_ROW_U8_KEY`,
`DB_TX_UPDATE_ROW_U8_KEY`, `DB_TX_DELETE_U8_KEY`, `DB_TX_UPSERT_ROW_I8_KEY`,
`DB_TX_UPDATE_ROW_I8_KEY`, `DB_TX_DELETE_I8_KEY`, `DB_TX_UPSERT_ROW_U16_KEY`,
`DB_TX_UPDATE_ROW_U16_KEY`, `DB_TX_DELETE_U16_KEY`, `DB_TX_UPSERT_ROW_I16_KEY`,
`DB_TX_UPDATE_ROW_I16_KEY`, and `DB_TX_DELETE_I16_KEY`, the signed-key forms `DB_TX_UPSERT_ROW_I64_KEY`,
`DB_TX_UPDATE_ROW_I64_KEY`, and `DB_TX_DELETE_I64_KEY`, plus the composite-key forms
`DB_TX_UPSERT_ROW_U64_PAIR_KEY`, `DB_TX_UPDATE_ROW_U64_PAIR_KEY`, and
`DB_TX_DELETE_U64_PAIR_KEY`, and the signed-second-key forms
`DB_TX_UPSERT_ROW_U64_I64_PAIR_KEY`, `DB_TX_UPDATE_ROW_U64_I64_PAIR_KEY`, and
`DB_TX_DELETE_U64_I64_PAIR_KEY`, plus unique text/blob-key forms
`DB_TX_UPSERT_ROW_BLOB_EQ_KEY`, `DB_TX_UPDATE_ROW_BLOB_EQ_KEY`, and
`DB_TX_DELETE_BLOB_EQ_KEY`, mutate a transaction image; no new table epoch or
manifest is published until `sa_db_tx_commit` / `DB_TX_COMMIT`. Commit writes
changed row segments when needed, versioned dictionary/blob artifacts referenced by the transaction metadata, rebuilds all
persisted indexes, then advances the active manifest once. Dictionary-only and
blob-only transactions are valid and advance the epoch without rewriting row
segments. A pending/commit marker pair
lets `recover` distinguish incomplete transaction metadata from committed
metadata whose manifest update was interrupted. If commit fails, for example
because a batch introduces duplicate keys for a unique index, the previous active
manifest remains visible and the transaction handle is closed. `sa_db_tx_rollback`
/ `DB_TX_ROLLBACK` drops the transaction image without publishing rows or blob
handles. This is currently a single-table, single-writer transaction model; read
handles still see only committed snapshots.

`sa_db_coltx_begin` / `DB_COLTX_BEGIN` starts a column-ingest session for
batch-oriented writes. Unlike `tx_begin`, it does not hold the global mutation
mutex across the whole session. `sa_db_coltx_add_columns` /
`DB_COLTX_ADD_COLUMNS` validates one fixed-width column batch, stages the column
files and hashes off the commit path, and keeps them private to the session.
The ABI handle registry now uses a shared lock plus per-session refcounts, so
different `coltx` sessions no longer serialize their `add_columns` staging I/O
behind one global mutex.
`sa_db_coltx_commit` / `DB_COLTX_COMMIT` then takes the table write lock once,
publishes every staged batch as new segments, rebuilds indexes, and advances the
manifest once. `sa_db_coltx_rollback` / `DB_COLTX_ROLLBACK` drops all staged
files. For multi-threaded ERP imports and large member-table loads, this is the
preferred write path over raw concurrent `sa_db_ingest_columns` calls.

`sa_db_upsert_row_u64_key` / `DB_UPSERT_ROW_U64_KEY` upserts one fixed-width row
by a unique `u64` key. The target column must already have a unique `u64` index.
When the key exists, the existing row is atomically replaced by rewriting the
table into a new column segment, rebuilding indexes, and advancing the epoch;
`out_inserted` is `0`. When the key is absent, the row is appended through the
same indexed ingest path and `out_inserted` is `1`. The `expected` key must match
the `u64` value encoded in the row's key column, otherwise the call returns
`SA_DB_ERR_INVALID_FORMAT` without committing a new epoch.

`sa_db_upsert_row_i64_key` / `DB_UPSERT_ROW_I64_KEY` provides the same strict
single-key row-write contract for a unique signed `i64` index. Use it for ERP
tables keyed by encoded dates, timestamps, signed sequence numbers, or other
signed business keys. Existing keys are replaced with `out_inserted=0`, missing
keys are appended with `out_inserted=1`, and the row's encoded `i64` key must
match the expected key argument.

`sa_db_upsert_row_u8_key`, `sa_db_upsert_row_i8_key`,
`sa_db_upsert_row_u16_key`, `sa_db_upsert_row_i16_key`,
`sa_db_upsert_row_u32_key`, and `sa_db_upsert_row_i32_key`, plus the matching
`DB_UPSERT_ROW_*_KEY` macros, provide the same strict single-key row-write
contract for compact integer keys. Use unsigned compact keys for ERP status,
channel, warehouse, location, line-number, or category IDs that do not need 64
bits, and signed compact keys for adjustment, priority, or small sequence
fields. The key column must have a unique index of the same compact type, the
row-encoded key must equal `expected`, and the direct and transaction variants
preserve the same `out_inserted` semantics.

`sa_db_upsert_row_u64_pair_key` / `DB_UPSERT_ROW_U64_PAIR_KEY` applies the same
strict row-write contract to a unique `u64_pair` index. The row's two key
columns must match `(key1, key2)`, and the table must already have a unique
`sa_db_create_u64_pair_index(..., unique=1)` index over those columns. This is
the ERP child-row primary-key path for shapes such as `(order_id, line_no)` or
`(product_id, warehouse_id)`: existing tuples are replaced with
`out_inserted=0`, missing tuples are appended with `out_inserted=1`, and all
persisted indexes are rebuilt for the new epoch.

`sa_db_upsert_row_u64_i64_pair_key` /
`DB_UPSERT_ROW_U64_I64_PAIR_KEY` applies the same strict row-write contract to a
unique `u64_i64_pair` index. The first key column is `u64`, the second key
column is signed `i64`, and the row bytes must encode exactly `(key1, key2)`.
This is the ERP composite-key path for signed second keys such as
`(customer_id, order_day)`, `(status_id, due_day)`, or
`(product_id, posted_day)`: existing tuples are replaced with
`out_inserted=0`, missing tuples are appended with `out_inserted=1`, and signed
ordering remains available for list/range reads after the write.

`sa_db_upsert_row_blob_eq_key` / `DB_UPSERT_ROW_BLOB_EQ_KEY` applies the same
strict row-write contract to a unique `blob_eq` index over one `blob_handle`
column and one named store. This is the ERP text/blob business-key path for
customer/vendor codes, SKU strings, document numbers, or external IDs. The row's
`blob_handle` must point at bytes equal to the key argument; existing keys are
replaced with `out_inserted=0`, missing keys are appended with `out_inserted=1`,
and all candidates are confirmed by real bytes so hash collisions cannot select
the wrong row. `sa_db_tx_upsert_row_blob_eq_key` /
`DB_TX_UPSERT_ROW_BLOB_EQ_KEY` provides the transaction-image variant.

`sa_db_update_row_u64_key` / `DB_UPDATE_ROW_U64_KEY` is the strict update form
for ERP screens that must not accidentally insert a new customer, order, item,
or ledger row. It has the same fixed-width row layout and unique-key requirement
as upsert, but it returns `SA_DB_ERR_NOT_FOUND` when the key is absent and never
appends. `sa_db_tx_update_row_u64_key` / `DB_TX_UPDATE_ROW_U64_KEY` provides the
same semantics inside a single-table transaction image.

`sa_db_update_row_i64_key` / `DB_UPDATE_ROW_I64_KEY` and
`sa_db_tx_update_row_i64_key` / `DB_TX_UPDATE_ROW_I64_KEY` provide the same
strict update semantics for unique signed `i64` keys.

`sa_db_update_row_u32_key` / `DB_UPDATE_ROW_U32_KEY`,
`sa_db_update_row_i32_key` / `DB_UPDATE_ROW_I32_KEY`, and their `DB_TX_*`
variants provide the same no-insert update semantics for unique compact integer
keys.

`sa_db_update_row_u64_pair_key` / `DB_UPDATE_ROW_U64_PAIR_KEY` is the strict
composite-key update form and never inserts a missing tuple. The transaction
variant `sa_db_tx_update_row_u64_pair_key` /
`DB_TX_UPDATE_ROW_U64_PAIR_KEY` works against the transaction image, so ERP
screens can modify multiple child rows and commit or roll them back together.

`sa_db_update_row_u64_i64_pair_key` /
`DB_UPDATE_ROW_U64_I64_PAIR_KEY` is the same strict update form for unique
`(u64, i64)` tuples and returns `SA_DB_ERR_NOT_FOUND` when the tuple is absent.
`sa_db_tx_update_row_u64_i64_pair_key` /
`DB_TX_UPDATE_ROW_U64_I64_PAIR_KEY` provides the transaction-image variant.

`sa_db_update_row_blob_eq_key` / `DB_UPDATE_ROW_BLOB_EQ_KEY` is the strict
no-insert update form for unique text/blob business keys. It returns
`SA_DB_ERR_NOT_FOUND` when the exact bytes are absent and
`SA_DB_ERR_INVALID_FORMAT` when the supplied row's `blob_handle` does not decode
to the same key bytes. `sa_db_tx_update_row_blob_eq_key` /
`DB_TX_UPDATE_ROW_BLOB_EQ_KEY` provides the transaction-image variant.

`sa_db_delete_u64_key` / `DB_DELETE_U64_KEY` deletes one row by a unique `u64`
key. The target column must already have a unique `u64` index, so the operation
has primary-key semantics instead of deleting an arbitrary non-unique match. The
delete rewrites the remaining rows into a new column segment, rebuilds indexes,
advances the epoch, and returns `SA_DB_ERR_NOT_FOUND` when the key is absent.

`sa_db_delete_i64_key` / `DB_DELETE_I64_KEY` and
`sa_db_tx_delete_i64_key` / `DB_TX_DELETE_I64_KEY` provide the same behavior for
unique signed `i64` keys.

`sa_db_delete_u8_key`, `sa_db_delete_i8_key`, `sa_db_delete_u16_key`,
`sa_db_delete_i16_key`, `sa_db_delete_u32_key`, and `sa_db_delete_i32_key`, plus
their `DB_DELETE_*` and transaction variants, delete one row by a unique compact
integer key and return `SA_DB_ERR_NOT_FOUND` when absent.

`sa_db_delete_u64_pair_key` / `DB_DELETE_U64_PAIR_KEY` deletes one row by a
unique `(u64, u64)` tuple. `sa_db_tx_delete_u64_pair_key` /
`DB_TX_DELETE_U64_PAIR_KEY` provides the same behavior inside a write
transaction. This covers deleting one order line or one inventory-balance row
without scanning the whole child table.

`sa_db_delete_u64_i64_pair_key` / `DB_DELETE_U64_I64_PAIR_KEY` deletes one row by
a unique `(u64, i64)` tuple. `sa_db_tx_delete_u64_i64_pair_key` /
`DB_TX_DELETE_U64_I64_PAIR_KEY` provides the same behavior inside a write
transaction for signed date/timestamp/amount second-key shapes.

`sa_db_delete_blob_eq_key` / `DB_DELETE_BLOB_EQ_KEY` deletes one row by a unique
text/blob business key and returns `SA_DB_ERR_NOT_FOUND` when the exact bytes are
absent. `sa_db_tx_delete_blob_eq_key` / `DB_TX_DELETE_BLOB_EQ_KEY` provides the
same behavior inside a write transaction.

`sa_db_dict_intern` / `DB_DICT_INTERN` provides the first string data-model layer
for ERP fields with small repeated value sets. `sa_db_tx_dict_intern` /
`DB_TX_DICT_INTERN` provides the same dictionary ID allocation inside a
single-table transaction, so a new status/category label and the rows that refer
to it commit or roll back together. The dictionary itself is a versioned table
artifact, so snapshot, restore, verify, recover, lock, unlock, and table removal
handle it with the same consistency rules as columns and indexes. It is not a
general varchar/blob store; it is intentionally optimized for stable labels that
can be represented as integer IDs in fixed-width rows. Read handles expose
dictionary lookup and ID-to-bytes helpers directly, which is the recommended path
for decoding list rows back to labels inside one snapshot.

`sa_db_blob_put` / `DB_BLOB_PUT` is the general variable-width layer for ERP text
and small/medium binary fields. Rows store a normal 8-byte `blob_handle` value,
while the named blob store owns the bytes. The blob artifact is part of the table
lifecycle: snapshot, restore, verify, recover, lock, unlock, and remove all carry
it with whole-file and block-level hashes. This keeps ordinary row/index queries
fixed-width while allowing notes, descriptions, addresses, and external payload
keys to live outside the column row buffer. `DB_CREATE_BLOB_EQ_INDEX` adds a
persisted exact index over those handles for high-frequency filters such as SKU,
external document key, address code, or normalized short text; `unique=1`
enforces uniqueness of the real bytes, not just the hash. `DB_FILTER_BLOB_EQ_HANDLE`
uses that index when present. `DB_CREATE_BLOB_TOKEN_INDEX` adds
case-insensitive ASCII token search over notes, addresses, item names, SKUs, and
external document labels. `DB_CREATE_BLOB_PREFIX_INDEX` adds the adjacent
case-insensitive token-prefix search shape for typeahead-like ERP filters such as
SKU prefixes, customer labels, and external document prefixes.
`DB_CREATE_BLOB_CONTAINS_INDEX` adds byte-level substring candidate indexing for
descriptions, notes, and external references that do not fit token or prefix
search; contains queries still confirm full bytes after index lookup.

The `db.sal` facade exposes matching helper macros: `DB_DECIMAL_FROM_PARTS`,
`DB_DECIMAL_TO_PARTS`, `DB_DATE_FROM_YMD`, `DB_DATE_TO_YMD`,
`DB_TIMESTAMP_MS_FROM_PARTS`, `DB_TIMESTAMP_MS_TO_PARTS`,
`DB_TIMESTAMP_US_FROM_PARTS`, `DB_TIMESTAMP_US_TO_PARTS`, `DB_BOOL_ENCODE`,
`DB_BOOL_DECODE`, `DB_NULL_BITMAP_REQUIRED_BYTES`, `DB_NULL_BITMAP_CLEAR`,
`DB_NULL_BITMAP_SET`, and `DB_NULL_BITMAP_GET`. `DB_DECIMAL_FROM_PARTS(1, 1, 0,
2)` encodes `-1.00` as `-100`, and a date such as `2024-02-29` encodes to epoch
day `19782`; callers can build normal signed indexes over those `i64` columns.
The typed range macros listed above now let SA query those same encoded columns
directly with business parameters such as decimal parts or Y-M-D dates.
When null state is stored as a logical `u8 null_bitmap` column, use
`sa_db_export_null_bitmap_handle` / `DB_EXPORT_NULL_BITMAP_HANDLE` to materialize
the packed bitmap for `*_NULL_BITMAP_HANDLE` range/filter calls.

This is still not a replacement for SQLite-style ACID, WAL, general
primary/secondary index planning, or multi-table transaction isolation. The v0.2
ERP foundation work is to extend the current single-table transaction/recovery
baseline into broader fault injection, optional WAL, richer indexes/search, and
multi-table semantics without losing the fast read-handle scan path.

## ERP Foundation Roadmap

The next development target is small/mid ERP suitability, not only OLAP SUM
benchmarks. The required baseline is:

- SA ERP benchmarks covering customers, products, inventory movement, sales
  orders, invoices/payments, and journal entries, with SQLite comparisons for
  single-threaded, concurrent, and mixed read/write workloads.
- Typed ERP storage for signed decimals, dates/times, booleans, nullable values,
  and dictionary-encoded strings. Primitive schema type codes, low-cardinality
  string dictionaries, and logical encode/decode helpers for decimal/date/time,
  bool, and null bitmaps exist now. Indexed `u8/i8/u16/i16/u32/i32/u64/i64/f32/f64`
  range reads exist for ERP list filters; `u64/i64` range wrappers can also apply
  a sidecar null bitmap before pagination, and decimal/date/timestamp typed range
  wrappers are available, including typed date/timestamp wrappers for the second
  key of `u64_i64_pair` ERP composite filters. `blob_handle` stores now cover variable-width text and
  bytes, with read-handle exact/contains/token/prefix filters; persisted exact,
  token, prefix, and trigram contains indexes cover high-frequency equality and
  text predicates.
- Row-oriented public operations on top of the column store: fixed-width insert,
  read by row index, unique typed integer key, unique composite key, or unique
  `blob_eq` text/blob key. Upsert/update/delete by unique `u64`, `u8`, `i8`, `u16`, `i16`, `u32`, `i32`, or `i64` key, unique `(u64, u64)` tuple, unique `(u64, i64)`
  tuple, or unique `blob_eq` text/blob key, range query handles, and single-table batch transactions exist now. Projected
  batch reads now cover the first ERP list-page shape. Indexed blob exact, token,
  prefix, and contains filters plus fixed-first-key `u64_pair` and
  `u64_i64_pair` filters cover common high-frequency text, child-row equality,
  customer/date, status/due-date, and product/posting-date shapes. Candidate row
  filters now compose an existing row-id list with additional integer, finite
  float, bool, or text/blob predicates for multi-condition list pages, row-list
  intersection/union/exclusion compose independently indexed result sets for
  AND/OR/not-in filters, two-predicate planners choose the smaller indexed side
  automatically for `u64+i64`, `u64+u64`, `i64+i64`, `u64+blob_eq`, and
  `i64+blob_eq` shapes, three-predicate planners cover `u64+i64+blob_eq`,
  `u64+i64+bool`, and `u64+i64+i64`, candidate row sorting covers integer
  and finite float list ordering, and nullable candidate-row filters now accept
  a sidecar null bitmap for `u64/i64` range predicates and the semantic
  decimal/date/timestamp wrappers that build on them. The first ERP workflow
  benchmark now covers customers, products, orders, order lines,
  inventory movement, and invoices, with a matching SQLite comparison for the
  same composite ERP filters; next is broader index planning.
- Generalized primary-key and secondary indexes beyond the current persisted
  small-integer, float, `u64`, `i64`, `u64_pair`, and `u64_i64_pair` index
  shapes, including broader planner support for common ERP filters and
  inventory/order workflows.
- Remaining crash-recovery hardening such as a broader fault-injection matrix,
  then multi-table transaction semantics, optional WAL, and async batch flush.
- mmap snapshots, block min/max indexes, predicate pushdown, and later SIMD
  aggregation as performance work after the reliability/data-model baseline.

## Benchmark

Benchmark sources and raw run data live in `benchmark_test/`.

All benchmark programs are written in SA. SQLite comparison programs use SA
`@extern sqlite3_*` calls to the system SQLite library.

Dataset:

- 50,000 member rows
- Columns: `id`, `plan`, `status`, `points`, all `u64`
- Concurrent query: 4 workers, 100 total full-table SUM queries
- Concurrent insert: 4 workers, 12,500 rows each
- ERP workflow: 1,024 customers, 512 products, 8,192 orders, 32,768 order
  lines, 16,384 inventory movements, and 8,192 invoices. It exercises
  dictionary-backed status fields, `i64` decimal/date columns, unique and
  non-unique `u64` indexes, `u64_pair` child-row indexes, `u64_i64_pair`
  customer/date and status/due-date indexes, typed date-pair range filters,
  count filters, projection, and verification across multiple tables. A dedicated
  smoke test covers typed timestamp-pair range wrappers over the same composite
  index shape.

Run db benchmarks:

```bash
cd /home/vscode/projects/sa_plugins/sa_plugin_db/benchmark_test
sa build-exe db_interface_smoke.sa -o db_interface_smoke.out --no-incremental
./db_interface_smoke.out

sa build-exe db_type_smoke.sa -o db_type_smoke.out --no-incremental
./db_type_smoke.out

sa build-exe db_typed_query_smoke.sa -o db_typed_query_smoke.out --no-incremental
./db_typed_query_smoke.out

sa build-exe db_timestamp_query_smoke.sa -o db_timestamp_query_smoke.out --no-incremental
./db_timestamp_query_smoke.out

sa build-exe db_u64_timestamp_pair_smoke.sa -o db_u64_timestamp_pair_smoke.out --no-incremental
./db_u64_timestamp_pair_smoke.out

sa build-exe db_u64_i64_pair_write_smoke.sa -o db_u64_i64_pair_write_smoke.out --no-incremental
./db_u64_i64_pair_write_smoke.out

sa build-exe db_i64_key_write_smoke.sa -o db_i64_key_write_smoke.out --no-incremental
./db_i64_key_write_smoke.out

sa build-exe db_u32_i32_key_write_smoke.sa -o db_u32_i32_key_write_smoke.out --no-incremental
./db_u32_i32_key_write_smoke.out

sa build-exe db_u8_i8_u16_i16_key_write_smoke.sa -o db_u8_i8_u16_i16_key_write_smoke.out --no-incremental
./db_u8_i8_u16_i16_key_write_smoke.out

sa build-exe db_typed_key_get_row_smoke.sa -o db_typed_key_get_row_smoke.out --no-incremental
./db_typed_key_get_row_smoke.out

sa build-exe db_pair_key_get_row_smoke.sa -o db_pair_key_get_row_smoke.out --no-incremental
./db_pair_key_get_row_smoke.out

sa build-exe db_blob_key_get_row_smoke.sa -o db_blob_key_get_row_smoke.out --no-incremental
./db_blob_key_get_row_smoke.out

sa build-exe db_blob_key_write_smoke.sa -o db_blob_key_write_smoke.out --no-incremental
./db_blob_key_write_smoke.out

sa build-exe db_candidate_filter_smoke.sa -o db_candidate_filter_smoke.out --no-incremental
./db_candidate_filter_smoke.out

sa build-exe db_planner_smoke.sa -o db_planner_smoke.out --no-incremental
./db_planner_smoke.out

sa build-exe db_blob_planner_smoke.sa -o db_blob_planner_smoke.out --no-incremental
./db_blob_planner_smoke.out

sa build-exe db_bool_planner_smoke.sa -o db_bool_planner_smoke.out --no-incremental
./db_bool_planner_smoke.out

sa build-exe db_i64_i64_planner_smoke.sa -o db_i64_i64_planner_smoke.out --no-incremental
./db_i64_i64_planner_smoke.out

sa build-exe db_tx_smoke.sa -o db_tx_smoke.out --no-incremental
./db_tx_smoke.out

sa build-exe db_tx_blob_smoke.sa -o db_tx_blob_smoke.out --no-incremental
./db_tx_blob_smoke.out

sa build-exe db_tx_dict_smoke.sa -o db_tx_dict_smoke.out --no-incremental
./db_tx_dict_smoke.out

sa build-exe db_blob_token_smoke.sa -o db_blob_token_smoke.out --no-incremental
./db_blob_token_smoke.out

sa build-exe db_blob_prefix_smoke.sa -o db_blob_prefix_smoke.out --no-incremental
./db_blob_prefix_smoke.out

sa build-exe db_blob_contains_smoke.sa -o db_blob_contains_smoke.out --no-incremental
./db_blob_contains_smoke.out

sa build-exe db_member_bench.sa -o db_member_bench.out --no-incremental
./db_member_bench.out

sa build-exe db_concurrent_bench.sa -o db_concurrent_bench.out --no-incremental
./db_concurrent_bench.out

sa build-exe db_erp_workflow_bench.sa -o db_erp_workflow_bench.out --no-incremental
./db_erp_workflow_bench.out
```

Run SQLite comparisons:

```bash
cd /home/vscode/projects/sa_plugins/sa_plugin_db/benchmark_test
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

Latest verified concurrent rerun results. Each benchmark now runs in its own
isolated root directory (`.bench_raw`, `.bench_coltx`, `.bench_sqlite`) so old
artifacts, WAL side files, and sibling benchmarks do not contaminate the next
run.

On 2026-06-18, a fresh 3-run isolated sample produced these medians:

- db raw read-handle benchmark: `167.317 ms` serial 100x SUM,
  `157.531 ms` concurrent 4x25 SUM, `95.736 ms` concurrent insert.
- db `coltx` benchmark: `143.751 ms` serial 100x SUM,
  `160.721 ms` concurrent 4x25 SUM, `72.192 ms` concurrent insert.
- SQLite control: `338.595 ms` serial 100x SUM, `197.866 ms` concurrent 4x25
  SUM, `108.089 ms` concurrent insert.

This rerun also confirms two behavioral changes: read handles now open during
active write transactions while still seeing only committed snapshots, and
`coltx` staging no longer serializes `add_columns` behind one global handle
mutex.

| Operation | db plugin | SQLite | Fastest |
| --- | ---: | ---: | --- |
| create/init | 6.711 ms | 0.596 ms | SQLite |
| bulk insert, 50k rows | 19.012 ms | 41.081 ms | db plugin |
| single SUM before update | 5.359 ms | 3.256 ms | SQLite |
| update all rows | 8.897 ms | 9.838 ms | db plugin |
| single SUM after update | 3.683 ms | 2.803 ms | SQLite |
| count `plan = 1` | 1.108 ms | 2.253 ms | db plugin |
| compact/vacuum | 20.293 ms | 5.597 ms | SQLite |
| verify/integrity | 11.624 ms | 3.518 ms | SQLite |
| serial 100x SUM with read handle | 167.317 ms | 338.595 ms | db plugin |
| concurrent 4x25 SUM with read handles | 157.531 ms | 197.866 ms | db plugin |
| concurrent insert, 4x12,500 rows, raw `ingest_columns` | 95.736 ms | 108.089 ms | db plugin |
| concurrent insert, 4x12,500 rows, `coltx` batch session | 72.192 ms | 108.089 ms* | db plugin |

`*` SQLite side only has one concurrent transaction-insert benchmark path; it
does not distinguish raw ingest from `coltx`.

ERP workflow 7-run median results:

| Operation | db plugin | SQLite | Fastest |
| --- | ---: | ---: | --- |
| init 6 ERP tables | 153.576 ms | 1.301 ms | SQLite |
| ingest ERP rows | 131.877 ms | 93.332 ms | SQLite |
| build ERP indexes | 175.708 ms | 19.449 ms | SQLite |
| order lines by order id | 0.019 ms | 0.052 ms | db plugin |
| project order line columns | 0.005 ms | 0.031 ms | db plugin |
| orders by customer/date | 0.006 ms | 0.028 ms | db plugin |
| paid due invoices by status/date | 0.010 ms | 0.248 ms | db plugin |
| inventory moves by product id | 0.007 ms | 0.027 ms | db plugin |
| verify/integrity | 147.362 ms | 38.938 ms | SQLite |

Summary:

- Reused read-handle queries are still faster than SQLite in this benchmark.
- The isolated-root rerun removed the earlier benchmark cross-contamination and
  kept db ahead of SQLite on serial and concurrent read-handle SUM.
- Read-handle open no longer waits on the global mutation mutex, so active write
  transactions do not block opening committed read snapshots.
- The latest raw concurrent rerun also beat SQLite on concurrent insert.
- Concurrent insert via the `coltx` batch session is the fastest path in the
  current benchmark set.
- ERP indexed list/projection queries favor the db plugin in the current
  workflow, especially status/date due-invoice scans and projected order lines.
- The concurrent insert suite still does not include explicit secondary-index
  maintenance, so ERP write-path conclusions should remain scoped to the tested
  workload.
- The earlier intermittent concurrent failures were not reproduced after moving
  each benchmark to a dedicated root and cleaning SQLite WAL/SHM side files.
- SQLite remains stronger for SQL, index creation, ACID, WAL, crash recovery,
  compact/vacuum, and integrity checks.

Detailed results: `benchmark_test/RESULTS.md`.

## Verification Status

The current development state has been verified with:

```bash
zig build test
zig build
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_db
```

The installed plugin exposes only the new read-handle query symbols; the removed
direct query symbols are no longer exported from `libdb.so`.
