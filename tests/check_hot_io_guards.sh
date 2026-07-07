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
require(
    r"fn\s+writeCompatMeta\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*if\s*\(!isMemoryRoot\(root_dir\)\)\s*try\s+ensureDeferredSchemaMaterialized\(allocator,\s*root_dir,\s*table_name\)",
    "no-sync compat meta writes must materialize disk schemas while preserving memory-root deferred schema",
    re.S,
)

require(r"fn\s+mappedReadFileMaxOwned\s*\(", "bounded mapped input helper is missing")
require(
    r"fn\s+writeArtifactFile\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*writeFileWithParentSync\(allocator,\s*path,\s*bytes,\s*false\)",
    "artifact writes must avoid per-artifact parent-directory fsync",
    re.S,
)
require(
    r"fn\s+writeFileWithParentSyncAndHashes\s*\([^)]*path:\s*\[\]const u8[^)]*bytes:\s*\[\]const u8[^)]*sync_parent:\s*bool[^)]*\)\s*TableError!FileWriteResult\s*\{(?:(?!\nfn\s).)*writeBytesToFileAndHashes(?:(?!\nfn\s).)*renamePath\(temp_path,\s*path\)(?:(?!\nfn\s).)*if\s*\(sync_parent\)\s*syncParentDirBestEffort\(path\)",
    "full-buffer artifact writes must combine file writes and hash metadata while preserving rename and optional parent sync",
    re.S,
)
require(
    r"fn\s+makeFileMetaFromWrite\s*\([^)]*written:\s*FileWriteResult[^)]*\)\s*TableError!FileMeta\s*\{(?:(?!\nfn\s).)*written\.hashes\.sha256(?:(?!\nfn\s).)*written\.bytes(?:(?!\nfn\s).)*written\.hashes\.block_sha256",
    "full-buffer artifact metadata must be built from write-time hashes",
    re.S,
)
forbid(
    r"\bmakeFileMeta\s*\(",
    "old full-buffer write-then-hash metadata helper reintroduced",
)
require(
    r"fn\s+makeCountedArtifactHashes\s*\([^)]*old_bytes:\s*\[\]const u8[^)]*new_count:\s*u64[^)]*values:\s*\[\]const \[\]const u8[^)]*\)\s*TableError!FileHashes\s*\{(?:(?!\nfn\s).)*updateCountedArtifactHashesWithValues",
    "counted dictionary/blob artifact append must stream hash metadata without a replacement artifact buffer",
    re.S,
)
require(
    r"fn\s+buildCountedArtifactBytesAndHashes\s*\([^)]*old_bytes:\s*\[\]const u8[^)]*new_count:\s*u64[^)]*values:\s*\[\]const \[\]const u8[^)]*\)\s*TableError!CountedArtifactBuildResult\s*\{(?:(?!\nfn\s).)*appendCountedArtifactBuildChunkAndHash",
    "staged dictionary/blob artifact builds must combine replacement-buffer construction and hash metadata",
    re.S,
)
require(
    r"fn\s+writeCountedArtifactFile\s*\([^)]*old_bytes:\s*\[\]const u8[^)]*new_count:\s*u64[^)]*values:\s*\[\]const \[\]const u8[^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*writeCountedArtifactToFile",
    "counted dictionary/blob artifact append must stream file writes without a replacement artifact buffer",
    re.S,
)
require(
    r"fn\s+writeCountedArtifactFileAndHashes\s*\([^)]*old_bytes:\s*\[\]const u8[^)]*new_count:\s*u64[^)]*values:\s*\[\]const \[\]const u8[^)]*\)\s*TableError!CountedArtifactWriteResult\s*\{(?:(?!\nfn\s).)*writeCountedArtifactToFileAndHashes",
    "direct counted dictionary/blob artifact append must combine durable file writes and hash metadata in one streaming pass",
    re.S,
)
require(
    r"fn\s+writeCountedArtifactFileAndHashes\s*\([^)]*old_bytes:\s*\[\]const u8[^)]*new_count:\s*u64[^)]*values:\s*\[\]const \[\]const u8[^)]*\)\s*TableError!CountedArtifactWriteResult\s*\{(?:(?!\nfn\s).)*MEMORY_PATH_PREFIX(?:(?!\nfn\s).)*buildCountedArtifactBytesAndHashes\(allocator,\s*old_bytes,\s*new_count,\s*values\)(?:(?!\nfn\s).)*memoryWriteFile\(allocator,\s*path,\s*built\.bytes\)",
    "memory counted dictionary/blob artifact append must build bytes and hash metadata in one pass",
    re.S,
)
forbid(
    r"fn\s+writeCountedArtifactFileAndHashes\s*\([^)]*\)\s*TableError!CountedArtifactWriteResult\s*\{(?:(?!\nfn\s).)*makeFileHashesSinglePass\(",
    "memory counted dictionary/blob artifact append reintroduced a second hash scan",
    re.S,
)
require(
    r"fn\s+flushPendingDictWrites\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*writeArtifactFile\(allocator,\s*path,\s*write\.bytes\)",
    "transaction dictionary artifact flush must use artifact writes",
    re.S,
)
require(
    r"fn\s+flushPendingBlobWrites\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*writeArtifactFile\(allocator,\s*path,\s*write\.bytes\)",
    "transaction blob artifact flush must use artifact writes",
    re.S,
)
require(
    r"fn\s+writeCompatMeta\s*\([^)]*\)\s*TableError!void\s*\{(?:(?!\nfn\s).)*pending_dict_writes(?:(?!\nfn\s).)*writeArtifactFile\(allocator,\s*path,\s*write\.bytes\)(?:(?!\nfn\s).)*pending_blob_writes(?:(?!\nfn\s).)*writeArtifactFile\(allocator,\s*path,\s*write\.bytes\)",
    "unsafe cached dictionary/blob materialization must use artifact writes before compat meta publish",
    re.S,
)
require(
    r"fn\s+writeSegmentFiles\b(?:(?!\nfn\s).)*writeFileWithParentSyncAndHashes\(allocator,\s*path,\s*buffer\.items,\s*false\)(?:(?!\nfn\s).)*makeFileMetaFromWrite\(allocator,\s*basename,\s*written\)",
    "segment file writes must build file metadata from write-time hashes",
    re.S,
)
require(
    r"fn\s+writeSegmentRawFiles\b(?:(?!\nfn\s).)*writeFileWithParentSyncAndHashes\(allocator,\s*path,\s*column\.bytes,\s*false\)(?:(?!\nfn\s).)*makeFileMetaFromWrite\(allocator,\s*basename,\s*written\)",
    "raw segment file writes must build file metadata from write-time hashes",
    re.S,
)
require(
    r"fn\s+stageRawColumnFiles\b(?:(?!\nfn\s).)*writeFileWithParentSyncAndHashes\(allocator,\s*staged_path,\s*column\.bytes,\s*false\)(?:(?!\nfn\s).)*written\.hashes\.sha256(?:(?!\nfn\s).)*written\.hashes\.block_sha256",
    "staged raw column writes must keep write-time hashes",
    re.S,
)
require(
    r"fn\s+mergeSegmentFiles\b(?:(?!\nfn\s).)*writeFileWithParentSyncAndHashes\(allocator,\s*dst_path,\s*merged\.items,\s*true\)(?:(?!\nfn\s).)*makeFileMetaFromWrite\(allocator,\s*basename,\s*written\)",
    "compact merge output writes must build file metadata from write-time hashes",
    re.S,
)
require(
    r"fn\s+rewriteColumnFileForEpoch\b(?:(?!\nfn\s).)*writeFileWithParentSyncAndHashes\(allocator,\s*active_next_path,\s*bytes,\s*true\)(?:(?!\nfn\s).)*makeFileMetaFromWrite\(allocator,\s*next_path,\s*written\)",
    "epoch column rewrite must build file metadata from write-time hashes",
    re.S,
)
require(
    r"fn\s+rewriteIndexMetaBytes\b(?:(?!\nfn\s).)*writeFileWithParentSyncAndHashes\(allocator,\s*path,\s*bytes,\s*false\)(?:(?!\nfn\s).)*index\.sha256\s*=\s*written\.hashes\.sha256",
    "index rewrite must keep write-time hashes",
    re.S,
)
require(
    r"fn\s+rebuildIndexAt\b(?:(?!\nfn\s).)*writeFileWithParentSyncAndHashes\(allocator,\s*path,\s*bytes,\s*false\)(?:(?!\nfn\s).)*index\.sha256\s*=\s*written\.hashes\.sha256",
    "index rebuild must keep write-time hashes",
    re.S,
)
require(
    r"pub\s+fn\s+internStringDict\s*\([^)]*\)\s*TableError!DictInternResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*writeCountedArtifactFileAndHashes\(allocator,\s*path,\s*old_bytes,\s*new_count,\s*&values\)(?:(?!\n(?:pub\s+)?fn\s).)*makeDictMetaFromCountedArtifactWrite\(allocator,\s*dict_name,\s*basename,\s*new_count,\s*written\)(?:(?!\n(?:pub\s+)?fn\s).)*try\s+writeMeta\(allocator,\s*root_dir,\s*table_name,\s*meta\)",
    "direct dictionary append must combine counted-artifact write/hash streaming before meta publish",
    re.S,
)
require(
    r"pub\s+fn\s+internStringDictMany\s*\([^)]*\)\s*TableError!DictInternManyResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*writeCountedArtifactFileAndHashes\(allocator,\s*path,\s*old_bytes,\s*new_count,\s*pending_values\[0\.\.pending_count\]\)(?:(?!\n(?:pub\s+)?fn\s).)*makeDictMetaFromCountedArtifactWrite\(allocator,\s*dict_name,\s*basename,\s*new_count,\s*written\)(?:(?!\n(?:pub\s+)?fn\s).)*try\s+writeMeta\(allocator,\s*root_dir,\s*table_name,\s*meta\)",
    "batched dictionary append must combine counted-artifact write/hash streaming before meta publish",
    re.S,
)
require(
    r"fn\s+dictScanCountAndFindValueIds\s*\([^)]*values:\s*\[\]const \[\]const u8[^)]*out_ids:\s*\[\]u64[^)]*\)\s*TableError!u64\s*\{(?:(?!\nfn\s).)*@memset\(out_ids,\s*0\)(?:(?!\nfn\s).)*for\s*\(values,\s*0\.\.\)\s*\|value,\s*idx\|(?:(?!\nfn\s).)*out_ids\[idx\]\s*=\s*current_id",
    "batched dictionary intern must scan existing dictionary bytes once for all requested values",
    re.S,
)
require(
    r"fn\s+unsafeInitCacheInternStringDictMany\s*\([^)]*\)\s*TableError!\?DictInternManyResult\s*\{(?:(?!\nfn\s).)*dictScanCountAndFindValueIds\(old_bytes,\s*values,\s*out_ids\)(?:(?!\nfn\s).)*if\s*\(out_ids\[idx\]\s*!=\s*0\)",
    "unsafe batched dictionary intern must use the single-pass old-dictionary scan",
    re.S,
)
require(
    r"fn\s+unsafeInitCacheInternStringDictMany\s*\([^)]*\)\s*TableError!\?DictInternManyResult\s*\{(?:(?!\nfn\s).)*buildCountedArtifactBytesAndHashes\(owned_allocator,\s*old_bytes,\s*new_count,\s*pending_values\[0\.\.pending_count\]\)(?:(?!\nfn\s).)*makeDictMetaFromCountedArtifactBuild\(owned_allocator,\s*dict_name,\s*basename,\s*new_count,\s*built\)",
    "unsafe batched dictionary intern must build staged bytes and hashes in one pass",
    re.S,
)
require(
    r"pub\s+fn\s+internStringDictMany\s*\([^)]*\)\s*TableError!DictInternManyResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*dictScanCountAndFindValueIds\(old_bytes,\s*values,\s*out_ids\)(?:(?!\n(?:pub\s+)?fn\s).)*if\s*\(out_ids\[idx\]\s*!=\s*0\)",
    "batched dictionary intern must use the single-pass old-dictionary scan",
    re.S,
)
forbid(
    r"fn\s+unsafeInitCacheInternStringDictMany\s*\([^)]*\)\s*TableError!\?DictInternManyResult\s*\{(?:(?!\nfn\s).)*dictFindValueId\(",
    "unsafe batched dictionary intern reintroduced repeated old-dictionary scans",
    re.S,
)
forbid(
    r"pub\s+fn\s+internStringDictMany\s*\([^)]*\)\s*TableError!DictInternManyResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*dictFindValueId\(",
    "batched dictionary intern reintroduced repeated old-dictionary scans",
    re.S,
)
require(
    r"pub\s+fn\s+putBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*writeCountedArtifactFileAndHashes\(allocator,\s*path,\s*old_bytes,\s*new_count,\s*&values\)(?:(?!\n(?:pub\s+)?fn\s).)*makeBlobStoreMetaFromCountedArtifactWrite\(allocator,\s*store_name,\s*basename,\s*new_count,\s*written\)(?:(?!\n(?:pub\s+)?fn\s).)*try\s+writeMeta\(allocator,\s*root_dir,\s*table_name,\s*meta\)",
    "direct blob append must combine counted-artifact write/hash streaming before meta publish",
    re.S,
)
require(
    r"pub\s+fn\s+internStringDict\s*\([^)]*\)\s*TableError!DictInternResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*canDeferUnsafeBootstrapMeta\(meta\)(?:(?!\n(?:pub\s+)?fn\s).)*buildCountedArtifactBytesAndHashes\(allocator,\s*old_bytes,\s*new_count,\s*&values\)(?:(?!\n(?:pub\s+)?fn\s).)*makeDictMetaFromCountedArtifactBuild\(allocator,\s*dict_name,\s*basename,\s*new_count,\s*built\)",
    "direct unsafe dictionary bootstrap must build staged bytes and hashes in one pass",
    re.S,
)
require(
    r"pub\s+fn\s+internStringDictMany\s*\([^)]*\)\s*TableError!DictInternManyResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*canDeferUnsafeBootstrapMeta\(meta\)(?:(?!\n(?:pub\s+)?fn\s).)*buildCountedArtifactBytesAndHashes\(allocator,\s*old_bytes,\s*new_count,\s*pending_values\[0\.\.pending_count\]\)(?:(?!\n(?:pub\s+)?fn\s).)*makeDictMetaFromCountedArtifactBuild\(allocator,\s*dict_name,\s*basename,\s*new_count,\s*built\)",
    "direct unsafe batched dictionary bootstrap must build staged bytes and hashes in one pass",
    re.S,
)
require(
    r"pub\s+fn\s+putBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*canDeferUnsafeBootstrapMeta\(meta\)(?:(?!\n(?:pub\s+)?fn\s).)*buildCountedArtifactBytesAndHashes\(allocator,\s*old_bytes,\s*new_count,\s*&values\)(?:(?!\n(?:pub\s+)?fn\s).)*makeBlobStoreMetaFromCountedArtifactBuild\(allocator,\s*store_name,\s*basename,\s*new_count,\s*built\)",
    "direct unsafe blob bootstrap must build staged bytes and hashes in one pass",
    re.S,
)
require(
    r"pub\s+fn\s+writeTransactionInternStringDict\s*\([^)]*\)\s*TableError!DictInternResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*buildCountedArtifactBytesAndHashes\(allocator,\s*old_bytes,\s*new_count,\s*&values\)(?:(?!\n(?:pub\s+)?fn\s).)*makeDictMetaFromCountedArtifactBuild\(allocator,\s*dict_name,\s*basename,\s*new_count,\s*built\)(?:(?!\n(?:pub\s+)?fn\s).)*putPendingDictWrite\(allocator,\s*tx,\s*dict_name,\s*basename,\s*built\.bytes\)",
    "transaction dictionary append must build pending bytes and hash metadata in one pass",
    re.S,
)
require(
    r"pub\s+fn\s+writeTransactionPutBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*buildCountedArtifactBytesAndHashes\(allocator,\s*old_bytes,\s*new_count,\s*&values\)(?:(?!\n(?:pub\s+)?fn\s).)*makeBlobStoreMetaFromCountedArtifactBuild\(allocator,\s*store_name,\s*basename,\s*new_count,\s*built\)(?:(?!\n(?:pub\s+)?fn\s).)*putPendingBlobWrite\(allocator,\s*tx,\s*store_name,\s*basename,\s*built\.bytes\)",
    "transaction blob append must build pending bytes and hash metadata in one pass",
    re.S,
)
forbid(
    r"pub\s+fn\s+internStringDict\s*\([^)]*\)\s*TableError!DictInternResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*makeDictMetaForCountedArtifactAppend\(",
    "direct dictionary append reintroduced separate counted-artifact hash pass",
    re.S,
)
forbid(
    r"pub\s+fn\s+internStringDictMany\s*\([^)]*\)\s*TableError!DictInternManyResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*makeDictMetaForCountedArtifactAppend\(",
    "batched dictionary append reintroduced separate counted-artifact hash pass",
    re.S,
)
forbid(
    r"pub\s+fn\s+putBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*makeBlobStoreMetaForCountedArtifactAppend\(",
    "direct blob append reintroduced separate counted-artifact hash pass",
    re.S,
)
forbid(
    r"pub\s+fn\s+writeTransactionInternStringDict\s*\([^)]*\)\s*TableError!DictInternResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*makeDictMeta\(allocator,\s*dict_name,\s*basename,\s*new_bytes,\s*new_count\)",
    "transaction dictionary append reintroduced separate pending-buffer hash pass",
    re.S,
)
forbid(
    r"pub\s+fn\s+writeTransactionPutBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*makeBlobStoreMeta\(allocator,\s*store_name,\s*basename,\s*new_bytes,\s*new_count\)",
    "transaction blob append reintroduced separate pending-buffer hash pass",
    re.S,
)
forbid(
    r"pub\s+fn\s+internStringDict\s*\([^)]*\)\s*TableError!DictInternResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*makeDictMeta\(allocator,\s*dict_name,\s*basename,\s*new_bytes,\s*new_count\)",
    "direct unsafe dictionary bootstrap reintroduced separate pending-buffer hash pass",
    re.S,
)
forbid(
    r"pub\s+fn\s+internStringDictMany\s*\([^)]*\)\s*TableError!DictInternManyResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*makeDictMeta\(allocator,\s*dict_name,\s*basename,\s*new_bytes,\s*new_count\)",
    "direct unsafe batched dictionary bootstrap reintroduced separate pending-buffer hash pass",
    re.S,
)
forbid(
    r"pub\s+fn\s+putBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*makeBlobStoreMeta\(allocator,\s*store_name,\s*basename,\s*new_bytes,\s*new_count\)",
    "direct unsafe blob bootstrap reintroduced separate pending-buffer hash pass",
    re.S,
)
forbid(
    r"pub\s+fn\s+internStringDict\s*\([^)]*\)\s*TableError!DictInternResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*writeArtifactFile\(allocator,\s*path,\s*new_bytes\)",
    "direct dictionary append reintroduced replacement-buffer artifact writes",
    re.S,
)
forbid(
    r"pub\s+fn\s+internStringDictMany\s*\([^)]*\)\s*TableError!DictInternManyResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*writeArtifactFile\(allocator,\s*path,\s*new_bytes\)",
    "batched dictionary append reintroduced replacement-buffer artifact writes",
    re.S,
)
forbid(
    r"pub\s+fn\s+putBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*writeArtifactFile\(allocator,\s*path,\s*new_bytes\)",
    "direct blob append reintroduced replacement-buffer artifact writes",
    re.S,
)
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
    r"test\s+\"table unsafe memory root write paths defer schema file materialization until verification\"(?:(?!\ntest\s+\").)*unsafe_no_sync_state\.store\(2(?:(?!\ntest\s+\").)*insertRawRow(?:(?!\ntest\s+\").)*commitWriteTransaction(?:(?!\ntest\s+\").)*commitColumnIngestSession(?:(?!\ntest\s+\").)*!fileExists\(schema_path\)(?:(?!\ntest\s+\").)*verifyTable(?:(?!\ntest\s+\").)*fileExists\(schema_path\)",
    "unsafe memory-root direct/tx/coltx writes must keep deferred schema unmaterialized until verification",
    re.S,
)
require(
    r"fn\s+indexReferencesBlobStore\s*\([^)]*\)\s*bool\s*\{(?:(?!\nfn\s).)*BLOB_EQ_INDEX_KIND(?:(?!\nfn\s).)*BLOB_TOKEN_INDEX_KIND(?:(?!\nfn\s).)*BLOB_PREFIX_INDEX_KIND(?:(?!\nfn\s).)*BLOB_CONTAINS_INDEX_KIND(?:(?!\nfn\s).)*index\.store_name",
    "blob append rebuild decisions must identify blob indexes by store",
    re.S,
)
require(
    r"fn\s+blobStoreAppendRequiresIndexRebuild\s*\([^)]*\)\s*TableError!bool\s*\{(?:(?!\nfn\s).)*indexReferencesBlobStore\(index,\s*store_name\)(?:(?!\nfn\s).)*mappedSegmentColumnBytes\(allocator,\s*root_dir,\s*segment,\s*column_index,\s*8\)(?:(?!\nfn\s).)*readU64LE\(bytes,\s*offset\)\s*==\s*appended_blob_id",
    "direct blob append must scan mapped blob-handle columns before deciding to rebuild blob indexes",
    re.S,
)
require(
    r"pub\s+fn\s+putBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*if\s*\(try\s+blobStoreAppendRequiresIndexRebuild\(allocator,\s*root_dir,\s*meta,\s*store_name,\s*new_count\)\)\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*try\s+rebuildBlobIndexesForStore\(allocator,\s*root_dir,\s*&meta,\s*store_name\)",
    "direct blob append must rebuild blob indexes only when existing rows reference the appended blob id",
    re.S,
)
require(
    r"test\s+\"table blob append skips index rebuild until appended blob is referenced\"(?:(?!\ntest\s+\").)*before_index_path(?:(?!\ntest\s+\").)*putBlobValue(?:(?!\ntest\s+\").)*expectEqualStrings\(before_index_path,\s*after_meta\.indexes\[0\]\.path\)(?:(?!\ntest\s+\").)*snapshotFilterBlobEqRows(?:(?!\ntest\s+\").)*insertRawRow(?:(?!\ntest\s+\").)*snapshotFilterBlobEqRows",
    "unreferenced direct blob append must keep index artifacts unchanged until a row references the appended blob",
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
    r"pub\s+fn\s+writeTransactionPutBlobValue\s*\([^)]*\)\s*TableError!BlobPutResult\s*\{(?:(?!\n(?:pub\s+)?fn\s).)*findPendingBlobWriteIndex\(tx,\s*store_name\)(?:(?!\n(?:pub\s+)?fn\s).)*putPendingBlobWrite\(allocator,\s*tx,\s*store_name,\s*basename,\s*built\.bytes\)",
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
