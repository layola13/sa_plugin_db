#!/usr/bin/env bash
set -euo pipefail

table_path="${1:-src/table.zig}"

if [[ -z "$table_path" || ! -f "$table_path" ]]; then
    echo "src/table.zig is required for hot I/O guard checks" >&2
    exit 1
fi

python3 - "$table_path" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text()


def fail(message: str) -> None:
    raise SystemExit(f"hot I/O guard failed: {message}")


def require(pattern: str, message: str, flags: int = 0) -> None:
    if not re.search(pattern, source, flags):
        fail(message)


def forbid(pattern: str, message: str, flags: int = 0) -> None:
    match = re.search(pattern, source, flags)
    if match:
        line = source.count("\n", 0, match.start()) + 1
        fail(f"{message} at {path}:{line}")


forbid(r"readFileAlloc\([^\n;]*1\s*<<\s*30", "1GiB readFileAlloc hot-path read reintroduced")
forbid(r"\breadDictBytes\s*\(", "owned dictionary read helper reintroduced")
forbid(r"\breadBlobStoreBytes\s*\(", "owned blob-store read helper reintroduced")

require(r"fn\s+mappedReadFileMaxOwned\s*\(", "bounded mapped input helper is missing")
require(
    r"fn\s+copyFile\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*mappedReadFileMaxOwned\(allocator,\s*src_path,\s*1\s*<<\s*30\)",
    "copyFile memory-root fallback must use bounded mapped input helper",
    re.S,
)
require(
    r"pub\s+fn\s+ingestTable\s*\([^)]*\)\s*TableError!TableInfo\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*mappedReadFileMaxOwned\(allocator,\s*data_path,\s*1\s*<<\s*30\)",
    "ingestTable must use bounded mapped input helper",
    re.S,
)
require(
    r"pub\s+fn\s+ingestTable\s*\([^)]*\)\s*TableError!TableInfo\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*const\s+previous_row_count\s*=\s*meta\.row_count;(?:(?!\n(?:pub\s+)?fn\s).)*appendSegmentToMeta\(allocator,\s*root_dir,\s*table_name,\s*&meta,\s*buffers,\s*row_count\);(?:(?!\n(?:pub\s+)?fn\s).)*tryAppendIndexesForSegment\(allocator,\s*root_dir,\s*&meta,\s*meta\.segments\.len\s*-\s*1,\s*previous_row_count,\s*null\)(?:(?!\n(?:pub\s+)?fn\s).)*if\s*\(!incremental_ok\)\s*try\s+rebuildIndexes\(allocator,\s*root_dir,\s*&meta\)",
    "ingestTable indexed append path must try incremental index maintenance before rebuild fallback",
    re.S,
)

require(
    r"const\s+CachedColumnBytes\s*=\s*struct\s*\{(?:(?!\n\};).)*MappedReadRegion",
    "append-index column cache must stay mapped-backed",
    re.S,
)
require(
    r"fn\s+getCachedSegmentColumnBytes\s*\([^)]*\)\s*TableError!\[\]const u8\s*\{(?:(?!\nfn\s).)*mappedSegmentColumnBytes\(",
    "append-index segment-column cache must read through mappedSegmentColumnBytes",
    re.S,
)
require(
    r"fn\s+mergeSegmentFiles\s*\([^)]*\)\s*TableError!\[\]FileMeta\s*\{(?:(?!\nfn\s).)*mappedSegmentColumnBytes\(",
    "compact merge inputs must read through mappedSegmentColumnBytes",
    re.S,
)
require(
    r"fn\s+buildAllColumnBuffers\s*\([^)]*\)\s*TableError!\[\]std\.ArrayList\(u8\)\s*\{(?:(?!\nfn\s).)*mappedSegmentColumnBytes\(",
    "full column-buffer rebuild inputs must read through mappedSegmentColumnBytes",
    re.S,
)
require(
    r"pub\s+fn\s+updateU64ColumnAdd\s*\([^)]*\)\s*TableError!u64\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*mappedSegmentColumnBytes\(",
    "u64 range-update old input must read through mappedSegmentColumnBytes",
    re.S,
)
require(
    r"pub\s+fn\s+updateU64ColumnAdd\s*\([^)]*\)\s*TableError!u64\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*if\s*\(update_count\s*==\s*0\s+or\s+delta\s*==\s*0\)\s*return\s+0;(?:(?!\n(?:pub\s+)?fn\s).)*const\s+next_epoch\s*=\s*owned\.epoch\s*\+\s*1",
    "u64 range-update must no-op before publishing artifacts when count or delta is zero",
    re.S,
)
require(
    r"fn\s+rebuildIndexesForColumn\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*indexReferencesColumn\(",
    "column-scoped index rebuild helper is missing",
    re.S,
)
require(
    r"fn\s+rewriteIndexesForDeletedRow\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*rewriteIndexForDeletedRow\(",
    "direct delete index rewrite helper is missing",
    re.S,
)
require(
    r"fn\s+rewriteIndexForDeletedRow\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*validateIndexMetaPath\(allocator,\s*root_dir,\s*index\.\*\)(?:(?!\nfn\s).)*rewriteSingleIndexBytesForDeletedRow",
    "direct delete index rewrite must validate old index bytes and handle single indexes",
    re.S,
)
require(
    r"fn\s+rewriteIndexForDeletedRow\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*validateIndexMetaPath\(allocator,\s*root_dir,\s*index\.\*\)(?:(?!\nfn\s).)*rewriteU64PairIndexBytesForDeletedRow",
    "direct delete index rewrite must validate old index bytes and handle pair indexes",
    re.S,
)
require(
    r"fn\s+deleteRowAtIndex\s*\([^)]*\)\s*TableError!TableInfo\s*\{(?:(?!\nfn\s).)*const\s+previous_row_count\s*=\s*meta\.row_count;(?:(?!\nfn\s).)*rewriteIndexesForDeletedRow\(allocator,\s*root_dir,\s*table_name,\s*meta,\s*previous_row_count,\s*row_index\)",
    "direct delete must rewrite existing indexes by filtering the deleted row",
    re.S,
)
forbid(
    r"fn\s+deleteRowAtIndex\s*\([^)]*\)\s*TableError!TableInfo\s*\{(?:(?!\nfn\s).)*rebuildIndexes\s*\(",
    "direct delete full-index rebuild reintroduced",
    re.S,
)
require(
    r"pub\s+fn\s+updateU64ColumnAdd\s*\([^)]*\)\s*TableError!u64\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*rebuildIndexesForColumn\(allocator,\s*root_dir,\s*&owned,\s*column_index\)",
    "u64 range-update must rebuild only indexes that reference the updated column",
    re.S,
)
require(
    r"fn\s+rebuildIndexesForChangedColumns\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*indexReferencesChangedColumns\(",
    "changed-column index rebuild helper is missing",
    re.S,
)
require(
    r"fn\s+changedColumnsAny\s*\([^)]*\)\s*bool\s*\{(?:(?!\nfn\s).)*if\s*\(changed\)\s*return\s+true",
    "changed-column no-op helper is missing",
    re.S,
)
require(
    r"fn\s+buildColumnBuffersReplacingRow\s*\([^)]*\)\s*TableError!ReplacedColumnBuffers\s*\{(?:(?!\nfn\s).)*changed_columns\[col_idx\]\s*=\s*true",
    "raw-row replacement must track changed columns",
    re.S,
)
require(
    r"fn\s+replaceRowAtIndex\s*\([^)]*\)\s*TableError!TableInfo\s*\{(?:(?!\nfn\s).)*if\s*\(!changedColumnsAny\(replaced\.changed_columns\)\)\s*return\s+tableInfo\(meta\.\*\)",
    "raw-row replacement must no-op before writing artifacts when no columns changed",
    re.S,
)
require(
    r"fn\s+replaceRowAtIndex\s*\([^)]*\)\s*TableError!TableInfo\s*\{(?:(?!\nfn\s).)*rebuildIndexesForChangedColumns\(allocator,\s*root_dir,\s*meta,\s*replaced\.changed_columns\)",
    "raw-row replacement must rebuild only indexes that reference changed columns",
    re.S,
)
require(
    r"pub\s+const\s+WriteTransaction\s*=\s*struct\s*\{(?:(?!\n\};).)*changed_columns:\s*\[\]bool\s*=\s*&\.\{\}(?:(?!\n\};).)*full_index_rebuild_required:\s*bool\s*=\s*false",
    "write transactions must track changed columns and full-index rebuild fallback state",
    re.S,
)
require(
    r"pub\s+const\s+WriteTransaction\s*=\s*struct\s*\{(?:(?!\n\};).)*deleted_rows:\s*\[\]u64\s*=\s*&\.\{\}(?:(?!\n\};).)*delete_index_filter_possible:\s*bool\s*=\s*true",
    "write transactions must track pure-delete rows and whether delete-index filtering remains safe",
    re.S,
)
require(
    r"pub\s+const\s+WriteTransaction\s*=\s*struct\s*\{(?:(?!\n\};).)*pending_blob_writes:\s*\[\]PendingBlobWrite\s*=\s*&\.\{\}(?:(?!\n\};).)*metadata_dirty:\s*bool\s*=\s*false",
    "write transactions must track pending blob artifact writes and metadata-only dirty state",
    re.S,
)
require(
    r"fn\s+materializeTransactionBuffers\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*if\s*\(tx\.pending_append_row_count\s*==\s*0\)\s*return;(?:(?!\nfn\s).)*markTransactionFullIndexRebuild\(tx\)(?:(?!\nfn\s).)*disableTransactionDeleteIndexFilter\(tx\)",
    "write transactions must force full rebuild and disable delete-index filtering when pending appends are materialized",
    re.S,
)
require(
    r"fn\s+transactionCanUseCommittedIndexLookup\s*\([^)]*\)\s*bool\s*\{(?:(?!\nfn\s).)*!tx\.dirty(?:(?!\nfn\s).)*!tx\.rows_dirty(?:(?!\nfn\s).)*tx\.buffers\.len\s*==\s*0(?:(?!\nfn\s).)*tx\.pending_append_buffers\.len\s*==\s*0(?:(?!\nfn\s).)*tx\.pending_append_row_count\s*==\s*0(?:(?!\nfn\s).)*tx\.deleted_rows\.len\s*==\s*0",
    "clean transaction committed-index lookup guard is missing or too broad",
    re.S,
)
require(
    r"fn\s+transactionCanUseAppendOnlyIndexLookup\s*\([^)]*\)\s*bool\s*\{(?:(?!\nfn\s).)*tx\.dirty(?:(?!\nfn\s).)*tx\.rows_dirty(?:(?!\nfn\s).)*tx\.buffers\.len\s*==\s*0(?:(?!\nfn\s).)*tx\.pending_append_buffers\.len\s*!=\s*0(?:(?!\nfn\s).)*tx\.pending_append_row_count\s*!=\s*0(?:(?!\nfn\s).)*tx\.deleted_rows\.len\s*==\s*0(?:(?!\nfn\s).)*tx\.delete_index_filter_possible(?:(?!\nfn\s).)*!tx\.full_index_rebuild_required",
    "append-only transaction key lookup guard is missing or too broad",
    re.S,
)
require(
    r"fn\s+committedTransactionMeta\s*\([^)]*\)\s*TableMeta\s*\{(?:(?!\nfn\s).)*var\s+meta\s*=\s*tx\.meta;(?:(?!\nfn\s).)*meta\.row_count\s*=\s*tx\.base_row_count",
    "append-only transaction lookup must validate committed indexes against the base row count",
    re.S,
)
require(
    r"fn\s+validateAppendOnlyTransactionLookup\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*transactionCanUseAppendOnlyIndexLookup\(tx\)(?:(?!\nfn\s).)*tx\.meta\.row_count\s*!=\s*expected_row_count(?:(?!\nfn\s).)*validateTransactionBuffers\(tx\)",
    "append-only transaction lookup must validate row counts and pending buffers before scanning",
    re.S,
)
require(
    r"fn\s+findPendingAppendScalarKeyRow\s*\([^)]*\)\s*TableError!U64FindResult\s*\{(?:(?!\nfn\s).)*validateAppendOnlyTransactionLookup\(tx\)(?:(?!\nfn\s).)*pendingAppendRowIndex\(tx,\s*pending_row\)",
    "append-only scalar key lookup must scan only pending append rows and return absolute row ids",
    re.S,
)
require(
    r"fn\s+findPendingAppendBlobEqKeyRow\s*\([^)]*\)\s*TableError!U64FindResult\s*\{(?:(?!\nfn\s).)*validateAppendOnlyTransactionLookup\(tx\)(?:(?!\nfn\s).)*transactionBlobStoreBytesForRead\(allocator,\s*tx,\s*tx\.meta\.blobs\[blob_idx\]\)(?:(?!\nfn\s).)*pendingAppendRowIndex\(tx,\s*pending_row\)",
    "append-only blob_eq key lookup must scan pending append rows against the transaction blob store view",
    re.S,
)
require(
    r"fn\s+transactionBlobStoreBytesForRead\s*\([^)]*\)\s*TableError!MappedReadRegion\s*\{(?:(?!\nfn\s).)*findPendingBlobWriteIndex\(tx,\s*blob\.name\)(?:(?!\nfn\s).)*validateBlobStoreBytes\(blob,\s*bytes\)(?:(?!\nfn\s).)*mappedBlobStoreBytesForRead\(allocator,\s*tx\.root_dir,\s*blob\)",
    "transaction blob store reads must prefer pending blob bytes before mapped committed artifacts",
    re.S,
)
require(
    r"fn\s+txFindUniqueBlobEqKeyRow\s*\([^)]*\)\s*TableError!U64FindResult\s*\{(?:(?!\nfn\s).)*transactionBlobStoreBytesForRead\(allocator,\s*tx,\s*meta\.blobs\[blob_idx\]\)(?:(?!\nfn\s).)*mappedIndexBytesForRead\(allocator,\s*tx\.root_dir,\s*index\)",
    "transaction committed blob_eq lookup must use transaction blob bytes while keeping mapped index reads",
    re.S,
)
require(
    r"fn\s+ensureTransactionRowBlobEqKeyValue\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*transactionBlobStoreBytesForRead\(allocator,\s*tx,\s*tx\.meta\.blobs\[blob_idx\]\)",
    "transaction blob_eq row validation must see pending blob bytes",
    re.S,
)
require(
    r"fn\s+txTryReplacePendingAppendRow\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*transactionCanUseAppendOnlyIndexLookup\(tx\)(?:(?!\nfn\s).)*validateAppendOnlyTransactionLookup\(tx\)(?:(?!\nfn\s).)*tx\.pending_append_buffers\[col_idx\]\.items",
    "pending append row replacement helper must validate append-only state and modify pending append buffers only",
    re.S,
)
require(
    r"fn\s+txTryDeletePendingAppendRow\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*transactionCanUseAppendOnlyIndexLookup\(tx\)(?:(?!\nfn\s).)*validateAppendOnlyTransactionLookup\(tx\)(?:(?!\nfn\s).)*removeBufferRange\(&tx\.pending_append_buffers\[col_idx\]",
    "pending append row delete helper must validate append-only state and remove from pending append buffers only",
    re.S,
)
forbid(
    r"fn\s+txTryReplacePendingAppendRow\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*materializeTransactionBuffers\(",
    "pending append row replacement helper must not materialize committed base",
    re.S,
)
forbid(
    r"fn\s+txTryDeletePendingAppendRow\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*materializeTransactionBuffers\(",
    "pending append row delete helper must not materialize committed base",
    re.S,
)
forbid(
    r"fn\s+txTryReplacePendingAppendRow\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*markTransactionChangedColumn\(",
    "pending append row replacement helper must not mark committed changed columns",
    re.S,
)
forbid(
    r"fn\s+txTryDeletePendingAppendRow\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*recordTransactionDeletedRow\(",
    "pending append row delete helper must not record committed-row deletes",
    re.S,
)
forbid(
    r"fn\s+txTryReplacePendingAppendRow\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*markTransactionFullIndexRebuild\(",
    "pending append row replacement helper must not force full index rebuild",
    re.S,
)
forbid(
    r"fn\s+txTryDeletePendingAppendRow\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*markTransactionFullIndexRebuild\(",
    "pending append row delete helper must not force full index rebuild",
    re.S,
)
forbid(
    r"fn\s+txTryReplacePendingAppendRow\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*disableTransactionDeleteIndexFilter\(",
    "pending append row replacement helper must not disable delete-index filtering",
    re.S,
)
forbid(
    r"fn\s+txTryDeletePendingAppendRow\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*disableTransactionDeleteIndexFilter\(",
    "pending append row delete helper must not disable delete-index filtering",
    re.S,
)

transaction_key_lookup_fast_paths = [
    ("txFindU64KeyRow", "findUniqueU64KeyRow"),
    ("txFindI64KeyRow", "findUniqueI64KeyRow"),
    ("txFindU32KeyRow", "findUniqueU32KeyRow"),
    ("txFindI32KeyRow", "findUniqueI32KeyRow"),
    ("txFindU8KeyRow", "findUniqueU8KeyRow"),
    ("txFindI8KeyRow", "findUniqueI8KeyRow"),
    ("txFindU16KeyRow", "findUniqueU16KeyRow"),
    ("txFindI16KeyRow", "findUniqueI16KeyRow"),
    ("txFindU64PairKeyRow", "findUniqueU64PairKeyRow"),
    ("txFindU64I64PairKeyRow", "findUniqueU64I64PairKeyRow"),
    ("txFindBlobEqKeyRow", "findUniqueBlobEqKeyRow"),
]
for tx_find, direct_find in transaction_key_lookup_fast_paths:
    require(
        rf"fn\s+{tx_find}\s*\([^)]*\)\s*TableError!U64FindResult\s*\{{(?:(?!materializeTransactionBuffers).)*transactionCanUseCommittedIndexLookup\(tx\)(?:(?!materializeTransactionBuffers).)*{direct_find}\(",
        f"{tx_find} must try committed unique-index lookup before materializing transaction buffers",
        re.S,
    )

transaction_key_lookup_append_fast_paths = [
    ("txFindU64KeyRow", "findUniqueU64KeyRow", r"findPendingAppendScalarKeyRow\(tx,\s*\.u64"),
    ("txFindI64KeyRow", "findUniqueI64KeyRow", r"findPendingAppendScalarKeyRow\(tx,\s*\.i64"),
    ("txFindU32KeyRow", "findUniqueU32KeyRow", r"findPendingAppendScalarKeyRow\(tx,\s*\.u32"),
    ("txFindI32KeyRow", "findUniqueI32KeyRow", r"findPendingAppendScalarKeyRow\(tx,\s*\.i32"),
    ("txFindU8KeyRow", "findUniqueU8KeyRow", r"findPendingAppendScalarKeyRow\(tx,\s*\.u8"),
    ("txFindI8KeyRow", "findUniqueI8KeyRow", r"findPendingAppendScalarKeyRow\(tx,\s*\.i8"),
    ("txFindU16KeyRow", "findUniqueU16KeyRow", r"findPendingAppendScalarKeyRow\(tx,\s*\.u16"),
    ("txFindI16KeyRow", "findUniqueI16KeyRow", r"findPendingAppendScalarKeyRow\(tx,\s*\.i16"),
    ("txFindU64PairKeyRow", "findUniqueU64PairKeyRow", r"findPendingAppendU64PairKeyRow\("),
    ("txFindU64I64PairKeyRow", "findUniqueU64I64PairKeyRow", r"findPendingAppendU64I64PairKeyRow\("),
    ("txFindBlobEqKeyRow", "txFindUniqueBlobEqKeyRow", r"findPendingAppendBlobEqKeyRow\("),
]
for tx_find, direct_find, pending_find in transaction_key_lookup_append_fast_paths:
    require(
        rf"fn\s+{tx_find}\s*\([^)]*\)\s*TableError!U64FindResult\s*\{{(?:(?!materializeTransactionBuffers).)*transactionCanUseAppendOnlyIndexLookup\(tx\)(?:(?!materializeTransactionBuffers).)*{direct_find}\([^;]*committedTransactionMeta\(tx\)(?:(?!materializeTransactionBuffers).)*{pending_find}",
        f"{tx_find} must check committed indexes and pending appends before materializing append-only transaction buffers",
        re.S,
    )

require(
    r"test\s+\"table clean transaction key lookup uses committed indexes without materializing buffers\"(?:(?!\ntest\s+\").)*txFindU64KeyRow(?:(?!\ntest\s+\").)*txFindI64KeyRow(?:(?!\ntest\s+\").)*txFindU64PairKeyRow(?:(?!\ntest\s+\").)*txFindU64I64PairKeyRow(?:(?!\ntest\s+\").)*txFindBlobEqKeyRow(?:(?!\ntest\s+\").)*expectCleanTransactionLookupDidNotMaterialize",
    "clean transaction committed-index lookup must keep typed/pair/blob no-materialization regression coverage",
    re.S,
)
require(
    r"test\s+\"table append-only transaction key lookup scans pending rows without materializing base\"(?:(?!\ntest\s+\").)*writeTransactionPutBlobValue(?:(?!\ntest\s+\").)*txFindU64KeyRow(?:(?!\ntest\s+\").)*txFindI64KeyRow(?:(?!\ntest\s+\").)*txFindU64PairKeyRow(?:(?!\ntest\s+\").)*txFindU64I64PairKeyRow(?:(?!\ntest\s+\").)*txFindBlobEqKeyRow(?:(?!\ntest\s+\").)*writeTransactionUpsertRawRowU64Key(?:(?!\ntest\s+\").)*writeTransactionUpdateRawRowU64Key(?:(?!\ntest\s+\").)*writeTransactionDeleteU64Key(?:(?!\ntest\s+\").)*expectAppendOnlyTransactionLookupDidNotMaterialize(?:(?!\ntest\s+\").)*commitWriteTransaction",
    "append-only transaction lookup must keep committed/pending typed/pair/blob no-materialization regression coverage",
    re.S,
)
require(
    r"fn\s+txReplaceRawRow\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!materializeTransactionBuffers).)*txTryReplacePendingAppendRow\(tx,\s*row_index,\s*row_bytes\)(?:(?!\nfn\s).)*materializeTransactionBuffers\(tx\)",
    "transaction row replacement must try pending append replacement before materializing committed base",
    re.S,
)
require(
    r"fn\s+txReplaceRawRow\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*markTransactionChangedColumn\(tx,\s*col_idx\)",
    "transaction row replacement must mark only actually changed columns",
    re.S,
)
require(
    r"fn\s+txReplaceRawRow\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*var\s+any_changed\s*=\s*false;(?:(?!\nfn\s).)*if\s*\(!any_changed\)\s*return;(?:(?!\nfn\s).)*tx\.dirty\s*=\s*true",
    "transaction row replacement must no-op before dirtying the transaction when no columns changed",
    re.S,
)
require(
    r"fn\s+originalRowAfterTransactionDeletes\s*\([^)]*\)\s*u64\s*\{(?:(?!\nfn\s).)*original_row\s*\+=\s*1",
    "transaction delete must be able to map current rows back to original rows",
    re.S,
)
require(
    r"fn\s+lowerBoundDeletedRow\s*\([^)]*\)\s*usize\s*\{(?:(?!\nfn\s).)*while\s*\(lo\s*<\s*hi\)(?:(?!\nfn\s).)*deleted_rows\[mid\]\s*<\s*row",
    "multi-row delete index rewrites must use sorted deleted-row lower-bound lookup",
    re.S,
)
require(
    r"fn\s+adjustedRowAfterDeletes\s*\([^)]*\)\s*\?u64\s*\{(?:(?!\nfn\s).)*lowerBoundDeletedRow\(deleted_rows,\s*row\)(?:(?!\nfn\s).)*deleted_rows\[deleted_before\]\s*==\s*row",
    "multi-row delete row adjustment must use lower-bound lookup and filter deleted rows",
    re.S,
)
require(
    r"fn\s+recordTransactionDeletedRow\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*tx\.deleted_rows",
    "transaction delete must record original deleted rows",
    re.S,
)
require(
    r"test\s+\"table write transaction delete rewrites blob indexes by filtering deleted rows\"(?:(?!\ntest\s+\").)*snapshotFilterBlobEqRows(?:(?!\ntest\s+\").)*snapshotFilterBlobTokenRows(?:(?!\ntest\s+\").)*snapshotFilterBlobPrefixRows(?:(?!\ntest\s+\").)*snapshotFilterBlobContainsRows",
    "pure transaction delete must keep blob eq/token/prefix/contains index rewrite coverage",
    re.S,
)
require(
    r"fn\s+rewriteIndexesForDeletedRows\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*rewriteIndexForDeletedRows\(",
    "multi-row delete index rewrite helper is missing",
    re.S,
)
require(
    r"fn\s+txDeleteRow\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*if\s*\(tx\.delete_index_filter_possible\)\s*\{(?:(?!\nfn\s).)*originalRowAfterTransactionDeletes\(tx\.deleted_rows,\s*row_index\)(?:(?!\nfn\s).)*recordTransactionDeletedRow\(tx,\s*original_row\)(?:(?!\nfn\s).)*markTransactionFullIndexRebuild\(tx\)",
    "transaction row deletion must record original rows before commit-time index filtering",
    re.S,
)
require(
    r"fn\s+txDeleteRow\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!materializeTransactionBuffers).)*txTryDeletePendingAppendRow\(tx,\s*row_index\)(?:(?!\nfn\s).)*materializeTransactionBuffers\(tx\)",
    "transaction row deletion must try pending append deletion before materializing committed base",
    re.S,
)
require(
    r"pub\s+fn\s+writeTransactionPutBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*findPendingBlobWriteIndex\(tx,\s*store_name\)(?:(?!\n(?:pub\s+)?fn\s).)*putPendingBlobWrite\(allocator,\s*tx,\s*store_name,\s*basename,\s*new_bytes\)",
    "transaction blob put must stage blob bytes in pending writes instead of publishing immediately",
    re.S,
)
forbid(
    r"pub\s+fn\s+writeTransactionPutBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*writeFile\(",
    "transaction blob put must not write blob artifacts before commit",
    re.S,
)
require(
    r"pub\s+fn\s+commitWriteTransaction\s*\([^)]*\)\s*TableError!TableInfo\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*flushPendingBlobWrites\(allocator,\s*tx\)(?:(?!appendPendingSegmentsFromTransaction).)*appendPendingSegmentsFromTransaction\(allocator,\s*tx\)(?:(?!\n(?:pub\s+)?fn\s).)*freePendingBlobWrites\(allocator,\s*tx\.pending_blob_writes\)",
    "transaction commit must flush pending blob writes before append-index maintenance and free them after publish",
    re.S,
)
require(
    r"test\s+\"table write transaction commits blob handles with rows atomically\"(?:(?!\ntest\s+\").)*tx\.pending_blob_writes\.len(?:(?!\ntest\s+\").)*!fileExists\(note_path\)(?:(?!\ntest\s+\").)*fileExists\(note_path\)(?:(?!\ntest\s+\").)*!fileExists\(rolled_back_path\)",
    "transaction blob tests must prove blob artifacts are pending until commit and absent after rollback",
    re.S,
)
require(
    r"test\s+\"table append-only transaction delete all pending rows stays unmaterialized no-op\"(?:(?!\ntest\s+\").)*writeTransactionInsertRawRow(?:(?!\ntest\s+\").)*writeTransactionDeleteU64Key(?:(?!\ntest\s+\").)*tx\.pending_append_buffers\.len(?:(?!\ntest\s+\").)*commitWriteTransaction",
    "pending append delete-all no-op must keep no-materialization regression coverage",
    re.S,
)
require(
    r"pub\s+fn\s+commitWriteTransaction\s*\([^)]*\)\s*TableError!TableInfo\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*rebuildIndexesForChangedColumns\(allocator,\s*tx\.root_dir,\s*&tx\.meta,\s*tx\.changed_columns\)",
    "transaction commit must rebuild only indexes that reference changed columns when no full rebuild is required",
    re.S,
)
require(
    r"pub\s+fn\s+commitWriteTransaction\s*\([^)]*\)\s*TableError!TableInfo\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*if\s*\(tx\.delete_index_filter_possible\s+and\s+tx\.deleted_rows\.len\s*!=\s*0\)\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*rewriteIndexesForDeletedRows\(allocator,\s*tx\.root_dir,\s*tx\.table_name,\s*&tx\.meta,\s*tx\.base_row_count,\s*tx\.deleted_rows\)(?:(?!\n(?:pub\s+)?fn\s).)*\}\s*else\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*rebuildIndexes\(allocator,\s*tx\.root_dir,\s*&tx\.meta\)",
    "transaction commit must filter indexes for pure delete transactions and keep full rebuild fallback",
    re.S,
)

print("hot I/O guard passed: mapped input paths and scoped index-maintenance guards are wired")
PY
