const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sa_repo_root = b.option([]const u8, "sa-repo-root", "SA repository root used to resolve the host binary.") orelse "/home/vscode/projects/sci";
    const sa_bin = b.option([]const u8, "sa-bin", "Path to the SA host binary used for db integration tests.") orelse b.pathJoin(&.{ sa_repo_root, "zig-out/bin/sa" });
    const sqlite_lib = b.option([]const u8, "sqlite-lib", "Path to the SQLite shared library used by SQLite control benchmarks.") orelse "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0";
    const sa_std_lib = b.option([]const u8, "sa-std-lib", "Path to libsa_std.a; SQLite control benchmarks rebuild it with sqlite stubs renamed.") orelse "/home/vscode/.sa/std/libsa_std.a";
    const bench_compare_runs = b.option(u32, "bench-compare-runs", "Positive odd number of runs for the opt-in bench-compare median gate.") orelse 3;
    const bench_compare_proof_runs = b.option(u32, "bench-compare-proof-runs", "Positive odd number of runs for the bench-compare-proof report gate.") orelse 7;
    requirePositiveOddRunCount("bench-compare-runs", bench_compare_runs);
    requirePositiveOddRunCount("bench-compare-proof-runs", bench_compare_proof_runs);
    const bench_compare_strict_chain = b.option(bool, "bench-compare-strict-chain", "Require the combined db tx+coltx append chain to beat SQLite append in bench-compare.") orelse false;
    const bench_compare_strict_concurrent_insert = b.option(bool, "bench-compare-strict-concurrent-insert", "Require db raw/coltx concurrent insert correctness and performance to beat SQLite in bench-compare-concurrent.") orelse false;
    const lock_wait_seconds = b.option(u32, "lock-wait-seconds", "Seconds to wait for shared build locks before failing instead of hanging.") orelse 900;
    const lock_wait_seconds_arg = b.fmt("{d}", .{lock_wait_seconds});
    const smoke_home = blk: {
        const smoke_home_opt = b.option([]const u8, "smoke-home", "SA_PLUGINS_HOME used by the install-smoke step.");
        if (smoke_home_opt) |smoke_home_value| {
            if (std.fs.path.isAbsolute(smoke_home_value)) break :blk smoke_home_value;
            break :blk b.pathFromRoot(smoke_home_value);
        }
        break :blk b.pathFromRoot(".zig-cache/db-install-smoke-home");
    };
    const bench_compare_home = blk: {
        const bench_home_opt = b.option([]const u8, "bench-compare-home", "SA_PLUGINS_HOME used by the bench-compare step.");
        if (bench_home_opt) |bench_home_value| {
            if (std.fs.path.isAbsolute(bench_home_value)) break :blk bench_home_value;
            break :blk b.pathFromRoot(bench_home_value);
        }
        break :blk b.pathFromRoot(".zig-cache/db-bench-compare-home");
    };

    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("plugin_api", plugin_api);

    const lib = b.addLibrary(.{
        .name = "db",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    // Ship the SA-facing interface facade alongside the native library.
    b.installFile("db.sai", "share/db.sai");
    b.installFile("db.sal", "share/db.sal");

    const tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_tests = b.addRunArtifact(tests);

    const interface_step = b.step("check-interfaces", "Verify benchmark_test interface copies stay synchronized.");
    const cmp_sai = b.addSystemCommand(&.{ "cmp", "-s", "db.sai", "benchmark_test/db.sai" });
    cmp_sai.addFileInput(b.path("db.sai"));
    cmp_sai.addFileInput(b.path("benchmark_test/db.sai"));
    interface_step.dependOn(&cmp_sai.step);

    const cmp_sal = b.addSystemCommand(&.{ "cmp", "-s", "db.sal", "benchmark_test/db.sal" });
    cmp_sal.addFileInput(b.path("db.sal"));
    cmp_sal.addFileInput(b.path("benchmark_test/db.sal"));
    interface_step.dependOn(&cmp_sal.step);

    const abi_symbols_step = b.step("check-abi-symbols", "Verify db.sai externs match exported libdb.so symbols.");
    const abi_symbols = b.addSystemCommand(&.{ "bash", "tests/check_abi_symbols.sh" });
    abi_symbols.addFileInput(b.path("tests/check_abi_symbols.sh"));
    abi_symbols.addFileArg(b.path("db.sai"));
    abi_symbols.addFileArg(lib.getEmittedBin());
    abi_symbols.step.dependOn(b.getInstallStep());
    abi_symbols_step.dependOn(&abi_symbols.step);

    const sal_facade_step = b.step("check-sal-facade", "Verify db.sal references every db.sai extern and no undeclared db symbols.");
    const sal_facade = b.addSystemCommand(&.{ "bash", "tests/check_sal_facade.sh" });
    sal_facade.addFileInput(b.path("tests/check_sal_facade.sh"));
    sal_facade.addFileArg(b.path("db.sai"));
    sal_facade.addFileArg(b.path("db.sal"));
    sal_facade_step.dependOn(&sal_facade.step);

    const manifest_layout_step = b.step("check-manifest-layout", "Verify sap.json policy and installed db plugin layout.");
    const manifest_source_check = b.addSystemCommand(&.{ "bash", "tests/check_manifest_layout.sh" });
    manifest_source_check.addFileInput(b.path("tests/check_manifest_layout.sh"));
    manifest_source_check.addFileArg(b.path("sap.json"));
    manifest_layout_step.dependOn(&manifest_source_check.step);

    const smoke_home_lock = b.pathFromRoot(".zig-cache/db-install-smoke-home.lock");
    const install_smoke_step = b.step("install-smoke", "Install the db plugin into an isolated home and verify the installed commands.");
    const install_smoke = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, smoke_home_lock, sa_bin, "plugin", "install", "--dev", "." });
    install_smoke.setEnvironmentVariable("SA_PLUGINS_HOME", smoke_home);
    install_smoke.setEnvironmentVariable("SA_PLUGIN_DEV", "1");
    install_smoke.addFileInput(b.path("sap.json"));
    install_smoke.addFileInput(b.path("db.sai"));
    install_smoke.addFileInput(b.path("db.sal"));
    install_smoke.addFileInput(lib.getEmittedBin());
    install_smoke.step.dependOn(b.getInstallStep());
    install_smoke_step.dependOn(&install_smoke.step);

    const installed_layout = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, smoke_home_lock, "bash", "tests/check_manifest_layout.sh" });
    installed_layout.addFileInput(b.path("tests/check_manifest_layout.sh"));
    installed_layout.addFileArg(b.path("sap.json"));
    installed_layout.addArg(b.pathJoin(&.{ smoke_home, "installed", "db", "current" }));
    installed_layout.addFileArg(b.path("db.sai"));
    installed_layout.addFileArg(b.path("db.sal"));
    installed_layout.addArg(b.pathFromRoot("zig-out/lib/libdb.so"));
    installed_layout.step.dependOn(&install_smoke.step);
    install_smoke_step.dependOn(&installed_layout.step);

    const cli_surface = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, smoke_home_lock, "bash", "tests/check_cli_surface.sh" });
    cli_surface.addFileInput(b.path("tests/check_cli_surface.sh"));
    cli_surface.addFileInput(b.path("src/plugin.zig"));
    cli_surface.addArg(sa_bin);
    cli_surface.addFileArg(b.path("src/plugin.zig"));
    cli_surface.setEnvironmentVariable("SA_PLUGINS_HOME", smoke_home);
    cli_surface.setEnvironmentVariable("SA_PLUGIN_DEV", "1");
    cli_surface.step.dependOn(&install_smoke.step);
    install_smoke_step.dependOn(&cli_surface.step);

    const smoke_verify = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, smoke_home_lock, "bash", "tests/smoke_installed.sh" });
    smoke_verify.addFileInput(b.path("tests/smoke_installed.sh"));
    smoke_verify.addFileInput(b.path("sap.json"));
    smoke_verify.addFileInput(b.path("db.sai"));
    smoke_verify.addFileInput(b.path("db.sal"));
    smoke_verify.addFileInput(lib.getEmittedBin());
    smoke_verify.setEnvironmentVariable("SA_PLUGIN_DB_SKIP_BUILD", "1");
    smoke_verify.setEnvironmentVariable("SA_PLUGIN_DB_SA_BIN", sa_bin);
    smoke_verify.setEnvironmentVariable("SA_PLUGIN_DB_SMOKE_HOME", smoke_home);
    smoke_verify.setEnvironmentVariable("SA_PLUGINS_HOME", smoke_home);
    smoke_verify.step.dependOn(&install_smoke.step);
    install_smoke_step.dependOn(&smoke_verify.step);

    const crash_recover_step = b.step("crash-recover-smoke", "Verify CLI recover handles stale manifests, tx markers, and corrupt meta/segment/index/dict artifacts.");
    const crash_recover = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, smoke_home_lock, "bash", "tests/crash_recover_smoke.sh" });
    crash_recover.addFileInput(b.path("tests/crash_recover_smoke.sh"));
    crash_recover.addFileInput(b.path("sap.json"));
    crash_recover.addFileInput(b.path("db.sai"));
    crash_recover.addFileInput(b.path("db.sal"));
    crash_recover.addFileInput(lib.getEmittedBin());
    crash_recover.setEnvironmentVariable("SA_PLUGIN_DB_SKIP_BUILD", "1");
    crash_recover.setEnvironmentVariable("SA_PLUGIN_DB_SA_BIN", sa_bin);
    crash_recover.setEnvironmentVariable("SA_PLUGIN_DB_SMOKE_HOME", smoke_home);
    crash_recover.setEnvironmentVariable("SA_PLUGINS_HOME", smoke_home);
    crash_recover.step.dependOn(&install_smoke.step);
    crash_recover_step.dependOn(&crash_recover.step);
    install_smoke_step.dependOn(&crash_recover.step);

    const abi_smoke_coverage_step = b.step("check-abi-smoke-coverage", "Verify every db_*_smoke.sa is included in abi-smoke.");
    const abi_smoke_coverage = b.addSystemCommand(&.{ "bash", "tests/check_abi_smoke_coverage.sh" });
    abi_smoke_coverage.addFileInput(b.path("tests/check_abi_smoke_coverage.sh"));
    abi_smoke_coverage.addFileInput(b.path("build.zig"));
    abi_smoke_coverage_step.dependOn(&abi_smoke_coverage.step);

    const check_docs_step = b.step("check-docs", "Verify tasks.md and progress.md mention current proof targets and parity caveats.");
    const check_docs = b.addSystemCommand(&.{ "bash", "tests/check_docs.sh" });
    check_docs.addFileInput(b.path("tests/check_docs.sh"));
    check_docs.addFileInput(b.path("tasks.md"));
    check_docs.addFileInput(b.path("progress.md"));
    check_docs.addFileInput(b.path("benchmark_test/RESULTS.md"));
    check_docs.addFileInput(b.path("build.zig"));
    check_docs_step.dependOn(&check_docs.step);

    const proof_wiring_step = b.step("check-proof-wiring", "Verify sqlite-audit and sqlite-proof dependency chains stay intact.");
    const proof_wiring = b.addSystemCommand(&.{ "bash", "tests/check_proof_wiring.sh" });
    proof_wiring.addFileInput(b.path("tests/check_proof_wiring.sh"));
    proof_wiring.addFileInput(b.path("build.zig"));
    proof_wiring_step.dependOn(&proof_wiring.step);

    const bounded_locks_step = b.step("check-bounded-locks", "Verify every shared build lock uses a bounded wait.");
    const bounded_locks = b.addSystemCommand(&.{ "bash", "tests/check_bounded_locks.sh" });
    bounded_locks.addFileInput(b.path("tests/check_bounded_locks.sh"));
    bounded_locks.addFileInput(b.path("build.zig"));
    bounded_locks_step.dependOn(&bounded_locks.step);

    const benchmark_parser_guards_step = b.step("check-benchmark-parser-guards", "Verify benchmark compare parser guards stay intact.");
    const benchmark_parser_guards = b.addSystemCommand(&.{ "bash", "tests/check_benchmark_parser_guards.sh" });
    benchmark_parser_guards.addFileInput(b.path("tests/check_benchmark_parser_guards.sh"));
    benchmark_parser_guards.addFileInput(b.path("build.zig"));
    benchmark_parser_guards_step.dependOn(&benchmark_parser_guards.step);

    const hot_io_guards_step = b.step("check-benchmark-hot-io-guards", "Verify hot benchmark input paths stay mapped and avoid broad heap-copy reads.");
    const hot_io_guards = b.addSystemCommand(&.{ "bash", "tests/check_hot_io_guards.sh" });
    hot_io_guards.addFileInput(b.path("tests/check_hot_io_guards.sh"));
    hot_io_guards.addFileArg(b.path("src/table.zig"));
    hot_io_guards_step.dependOn(&hot_io_guards.step);

    const abi_smoke_step = b.step("abi-smoke", "Build and run broad SA-facing db.sal ABI smokes.");
    abi_smoke_step.dependOn(abi_smoke_coverage_step);
    const abi_smoke_sources = [_][]const u8{
        "benchmark_test/db_blob_contains_smoke.sa",
        "benchmark_test/db_blob_filter_smoke.sa",
        "benchmark_test/db_blob_index_smoke.sa",
        "benchmark_test/db_blob_key_get_row_smoke.sa",
        "benchmark_test/db_blob_key_write_smoke.sa",
        "benchmark_test/db_blob_planner_smoke.sa",
        "benchmark_test/db_blob_prefix_smoke.sa",
        "benchmark_test/db_blob_store_smoke.sa",
        "benchmark_test/db_blob_token_smoke.sa",
        "benchmark_test/db_bool_planner_smoke.sa",
        "benchmark_test/db_bool_query_smoke.sa",
        "benchmark_test/db_candidate_filter_smoke.sa",
        "benchmark_test/db_compact_candidate_filter_smoke.sa",
        "benchmark_test/db_compact_candidate_sort_smoke.sa",
        "benchmark_test/db_compact_numeric_smoke.sa",
        "benchmark_test/db_date_decimal_planner_smoke.sa",
        "benchmark_test/db_float_query_smoke.sa",
        "benchmark_test/db_group_stats_smoke.sa",
        "benchmark_test/db_group_sum_smoke.sa",
        "benchmark_test/db_i64_i64_planner_smoke.sa",
        "benchmark_test/db_i64_key_write_smoke.sa",
        "benchmark_test/db_interface_smoke.sa",
        "benchmark_test/db_lifecycle_smoke.sa",
        "benchmark_test/db_memory_exact_smoke.sa",
        "benchmark_test/db_memory_smoke.sa",
        "benchmark_test/db_pair_key_get_row_smoke.sa",
        "benchmark_test/db_planner_smoke.sa",
        "benchmark_test/db_small_numeric_smoke.sa",
        "benchmark_test/db_timestamp_query_smoke.sa",
        "benchmark_test/db_tx_blob_smoke.sa",
        "benchmark_test/db_tx_dict_smoke.sa",
        "benchmark_test/db_tx_smoke.sa",
        "benchmark_test/db_type_smoke.sa",
        "benchmark_test/db_typed_key_get_row_smoke.sa",
        "benchmark_test/db_typed_query_smoke.sa",
        "benchmark_test/db_u32_i32_key_write_smoke.sa",
        "benchmark_test/db_u64_i64_pair_smoke.sa",
        "benchmark_test/db_u64_i64_pair_write_smoke.sa",
        "benchmark_test/db_u64_pair_key1_smoke.sa",
        "benchmark_test/db_u64_pair_write_smoke.sa",
        "benchmark_test/db_u64_timestamp_pair_smoke.sa",
        "benchmark_test/db_u8_i8_u16_i16_key_write_smoke.sa",
        "benchmark_test/db_update_row_smoke.sa",
    };
    for (abi_smoke_sources) |source_rel| {
        const base_name = std.fs.path.basename(source_rel);
        const out_name = b.fmt("{s}.out", .{std.fs.path.stem(base_name)});
        const smoke = addSaSmokeStep(b, sa_bin, smoke_home, smoke_home_lock, lock_wait_seconds_arg, &install_smoke.step, source_rel, out_name);
        abi_smoke_step.dependOn(&smoke.step);
    }

    const test_step = b.step("test", "Run db plugin tests and host install smoke.");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(interface_step);
    test_step.dependOn(abi_symbols_step);
    test_step.dependOn(sal_facade_step);
    test_step.dependOn(manifest_layout_step);
    test_step.dependOn(install_smoke_step);
    test_step.dependOn(crash_recover_step);
    test_step.dependOn(abi_smoke_coverage_step);
    test_step.dependOn(abi_smoke_step);
    test_step.dependOn(check_docs_step);
    test_step.dependOn(proof_wiring_step);
    test_step.dependOn(bounded_locks_step);
    test_step.dependOn(benchmark_parser_guards_step);
    test_step.dependOn(hot_io_guards_step);

    const bench_step = b.step("bench", "Build the main db and SQLite control benchmark executables.");
    const bench_compare_home_lock = b.pathFromRoot(".zig-cache/db-bench-compare-home.lock");
    const install_bench_compare = addDevInstallStep(b, sa_bin, bench_compare_home, bench_compare_home_lock, lock_wait_seconds_arg, lib);
    _ = addSaBenchStep(b, bench_step, sa_bin, bench_compare_home, bench_compare_home_lock, lock_wait_seconds_arg, &install_bench_compare.step, "benchmark_test/db_member_bench.sa", "db_member_bench.out");
    const db_concurrent_bench = addSaBenchStep(b, bench_step, sa_bin, bench_compare_home, bench_compare_home_lock, lock_wait_seconds_arg, &install_bench_compare.step, "benchmark_test/db_concurrent_bench.sa", "db_concurrent_bench.out");
    const db_coltx_concurrent_bench = addSaBenchStep(b, bench_step, sa_bin, bench_compare_home, bench_compare_home_lock, lock_wait_seconds_arg, &install_bench_compare.step, "benchmark_test/db_coltx_concurrent_bench.sa", "db_coltx_concurrent_bench.out");
    _ = addSaBenchStep(b, bench_step, sa_bin, bench_compare_home, bench_compare_home_lock, lock_wait_seconds_arg, &install_bench_compare.step, "benchmark_test/db_erp_workflow_bench.sa", "db_erp_workflow_bench.out");
    const db_indexed_write_bench = addSaBenchStep(b, bench_step, sa_bin, bench_compare_home, bench_compare_home_lock, lock_wait_seconds_arg, &install_bench_compare.step, "benchmark_test/db_erp_indexed_write_bench.sa", "db_erp_indexed_write_bench.out");
    const db_indexed_memory_bench = addSaBenchStep(b, bench_step, sa_bin, bench_compare_home, bench_compare_home_lock, lock_wait_seconds_arg, &install_bench_compare.step, "benchmark_test/db_erp_indexed_memory_bench.sa", "db_erp_indexed_memory_bench.out");

    const sqlite_std_archive = addSqliteStdArchiveStep(b, sa_std_lib);
    _ = addSqliteBenchStep(b, bench_step, sa_bin, sqlite_std_archive, sqlite_lib, "benchmark_test/sqlite_member_bench.sa", "sqlite_member_bench.out");
    const sqlite_concurrent_bench = addSqliteBenchStep(b, bench_step, sa_bin, sqlite_std_archive, sqlite_lib, "benchmark_test/sqlite_concurrent_bench.sa", "sqlite_concurrent_bench.out");
    _ = addSqliteBenchStep(b, bench_step, sa_bin, sqlite_std_archive, sqlite_lib, "benchmark_test/sqlite_erp_workflow_bench.sa", "sqlite_erp_workflow_bench.out");
    const sqlite_indexed_write_bench = addSqliteBenchStep(b, bench_step, sa_bin, sqlite_std_archive, sqlite_lib, "benchmark_test/sqlite_erp_indexed_write_bench.sa", "sqlite_erp_indexed_write_bench.out");
    const sqlite_indexed_memory_bench = addSqliteBenchStep(b, bench_step, sa_bin, sqlite_std_archive, sqlite_lib, "benchmark_test/sqlite_erp_indexed_memory_bench.sa", "sqlite_erp_indexed_memory_bench.out");

    const bench_compare_step = b.step("bench-compare", "Run indexed ERP and concurrent db-vs-SQLite median comparison gates.");
    const bench_compare_disk_step = b.step("bench-compare-disk", "Run the disk indexed ERP db-vs-SQLite median comparison gate.");
    const bench_compare_memory_step = b.step("bench-compare-memory", "Run the memory indexed ERP db-vs-SQLite median comparison gate.");
    const bench_compare_concurrent_step = b.step("bench-compare-concurrent", "Run the concurrent db-vs-SQLite median comparison gate.");
    const bench_compare_concurrent_strict_insert_step = b.step("bench-compare-concurrent-strict-insert", "Run the concurrent db-vs-SQLite gate with strict concurrent insert correctness and performance.");
    const bench_compare_disk_strict_chain_step = b.step("bench-compare-disk-strict-chain", "Run the disk indexed ERP strict combined append-chain gate.");
    const bench_compare_memory_strict_chain_step = b.step("bench-compare-memory-strict-chain", "Run the memory indexed ERP strict combined append-chain gate.");
    const bench_compare_proof_step = b.step("bench-compare-proof", "Run the configured-run SQLite proof report (positive odd, default 7): disk+memory compare plus strict concurrent insert.");
    const bench_compare_proof_strict_chain_step = b.step("bench-compare-proof-strict-chain", "Run the configured-run SQLite proof (positive odd, default 7) with disk/memory combined append chain as hard gates.");
    const sqlite_proof_step = b.step("sqlite-proof", "Run SQLite readiness audit plus the configured-run performance proof report (positive odd, default 7).");
    const sqlite_proof_strict_chain_step = b.step("sqlite-proof-strict-chain", "Run SQLite readiness audit plus the strict-chain configured-run performance proof (positive odd, default 7).");
    const benchmark_artifacts_step = b.step("check-benchmark-artifacts", "Verify protected tracked benchmark artifacts are clean.");
    const benchmark_run_lock = b.pathFromRoot(".zig-cache/db-benchmark-run.lock");
    const benchmark_artifacts = addBenchmarkArtifactGuardStep(b, benchmark_run_lock, lock_wait_seconds_arg);
    benchmark_artifacts_step.dependOn(&benchmark_artifacts.step);
    test_step.dependOn(benchmark_artifacts_step);

    const sqlite_audit_step = b.step("sqlite-audit", "Run non-benchmark SQLite-readiness gates and protected artifact audit.");
    const sqlite_audit_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        "printf '%s\n' 'sqlite-audit passed: zig tests, docs guard, ABI/facade/layout, install+CLI/recovery smokes, ABI smoke coverage, public ABI smokes, benchmark executable builds, benchmark parser guards, proof wiring, bounded lock guard, and protected benchmark artifacts are clean'",
    });
    sqlite_audit_summary.step.dependOn(test_step);
    sqlite_audit_summary.step.dependOn(bench_step);
    sqlite_audit_summary.step.dependOn(benchmark_artifacts_step);
    sqlite_audit_step.dependOn(&sqlite_audit_summary.step);

    const bench_compare = addBenchCompareStep(b, db_indexed_write_bench, sqlite_indexed_write_bench, bench_compare_runs, bench_compare_strict_chain, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg, "disk indexed ERP", "db_erp_indexed", "sqlite_erp_indexed");
    bench_compare.step.dependOn(&install_bench_compare.step);
    bench_compare.step.dependOn(&benchmark_artifacts.step);
    bench_compare_step.dependOn(&bench_compare.step);
    const bench_compare_disk = addBenchCompareStep(b, db_indexed_write_bench, sqlite_indexed_write_bench, bench_compare_runs, bench_compare_strict_chain, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg, "disk indexed ERP", "db_erp_indexed", "sqlite_erp_indexed");
    bench_compare_disk.step.dependOn(&install_bench_compare.step);
    bench_compare_disk.step.dependOn(&benchmark_artifacts.step);
    const bench_compare_disk_artifacts = addBenchmarkArtifactGuardStep(b, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_disk_artifacts.step.dependOn(&bench_compare_disk.step);
    const bench_compare_disk_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'bench-compare-disk passed: runs={d} disk indexed ERP compare and protected artifact guard completed'", .{bench_compare_runs}),
    });
    bench_compare_disk_summary.step.dependOn(&bench_compare_disk_artifacts.step);
    bench_compare_disk_step.dependOn(&bench_compare_disk_summary.step);
    const bench_compare_memory = addBenchCompareStep(b, db_indexed_memory_bench, sqlite_indexed_memory_bench, bench_compare_runs, bench_compare_strict_chain, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg, "memory indexed ERP", "db_erp_indexed_memory", "sqlite_erp_indexed_memory");
    bench_compare_memory.step.dependOn(&install_bench_compare.step);
    bench_compare_memory.step.dependOn(&benchmark_artifacts.step);
    const bench_compare_memory_artifacts = addBenchmarkArtifactGuardStep(b, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_memory_artifacts.step.dependOn(&bench_compare_memory.step);
    const bench_compare_memory_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'bench-compare-memory passed: runs={d} memory indexed ERP compare and protected artifact guard completed'", .{bench_compare_runs}),
    });
    bench_compare_memory_summary.step.dependOn(&bench_compare_memory_artifacts.step);
    bench_compare_memory_step.dependOn(&bench_compare_memory_summary.step);
    const bench_compare_memory_after_disk = addBenchCompareStep(b, db_indexed_memory_bench, sqlite_indexed_memory_bench, bench_compare_runs, bench_compare_strict_chain, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg, "memory indexed ERP", "db_erp_indexed_memory", "sqlite_erp_indexed_memory");
    bench_compare_memory_after_disk.step.dependOn(&install_bench_compare.step);
    bench_compare_memory_after_disk.step.dependOn(&bench_compare.step);
    bench_compare_step.dependOn(&bench_compare_memory_after_disk.step);
    const bench_compare_concurrent = addBenchCompareConcurrentStep(b, db_concurrent_bench, db_coltx_concurrent_bench, sqlite_concurrent_bench, bench_compare_runs, bench_compare_strict_concurrent_insert, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_concurrent.step.dependOn(&install_bench_compare.step);
    bench_compare_concurrent.step.dependOn(&benchmark_artifacts.step);
    const bench_compare_concurrent_artifacts = addBenchmarkArtifactGuardStep(b, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_concurrent_artifacts.step.dependOn(&bench_compare_concurrent.step);
    const bench_compare_concurrent_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'bench-compare-concurrent passed: runs={d} concurrent compare and protected artifact guard completed'", .{bench_compare_runs}),
    });
    bench_compare_concurrent_summary.step.dependOn(&bench_compare_concurrent_artifacts.step);
    bench_compare_concurrent_step.dependOn(&bench_compare_concurrent_summary.step);

    const bench_compare_concurrent_strict_insert = addBenchCompareConcurrentStep(b, db_concurrent_bench, db_coltx_concurrent_bench, sqlite_concurrent_bench, bench_compare_proof_runs, true, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_concurrent_strict_insert.step.dependOn(&install_bench_compare.step);
    bench_compare_concurrent_strict_insert.step.dependOn(&benchmark_artifacts.step);
    const bench_compare_concurrent_strict_insert_artifacts = addBenchmarkArtifactGuardStep(b, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_concurrent_strict_insert_artifacts.step.dependOn(&bench_compare_concurrent_strict_insert.step);
    const bench_compare_concurrent_strict_insert_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'bench-compare-concurrent-strict-insert passed: runs={d} strict raw/coltx concurrent insert proof and protected artifact guard completed'", .{bench_compare_proof_runs}),
    });
    bench_compare_concurrent_strict_insert_summary.step.dependOn(&bench_compare_concurrent_strict_insert_artifacts.step);
    bench_compare_concurrent_strict_insert_step.dependOn(&bench_compare_concurrent_strict_insert_summary.step);

    const bench_compare_concurrent_after_indexed = addBenchCompareConcurrentStep(b, db_concurrent_bench, db_coltx_concurrent_bench, sqlite_concurrent_bench, bench_compare_runs, bench_compare_strict_concurrent_insert, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_concurrent_after_indexed.step.dependOn(&install_bench_compare.step);
    bench_compare_concurrent_after_indexed.step.dependOn(&bench_compare_memory_after_disk.step);
    const bench_compare_artifacts = addBenchmarkArtifactGuardStep(b, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_artifacts.step.dependOn(&bench_compare_concurrent_after_indexed.step);
    const bench_compare_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'bench-compare passed: runs={d} disk indexed ERP, memory indexed ERP, concurrent compare, and protected artifact guard completed'", .{bench_compare_runs}),
    });
    bench_compare_summary.step.dependOn(&bench_compare_artifacts.step);
    bench_compare_step.dependOn(&bench_compare_summary.step);

    const bench_compare_disk_strict_chain = addBenchCompareStep(b, db_indexed_write_bench, sqlite_indexed_write_bench, bench_compare_proof_runs, true, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg, "disk indexed ERP", "db_erp_indexed", "sqlite_erp_indexed");
    bench_compare_disk_strict_chain.step.dependOn(&install_bench_compare.step);
    bench_compare_disk_strict_chain.step.dependOn(&benchmark_artifacts.step);
    const bench_compare_disk_strict_chain_artifacts = addBenchmarkArtifactGuardStep(b, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_disk_strict_chain_artifacts.step.dependOn(&bench_compare_disk_strict_chain.step);
    const bench_compare_disk_strict_chain_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'bench-compare-disk-strict-chain passed: runs={d} disk strict combined append proof and protected artifact guard completed'", .{bench_compare_proof_runs}),
    });
    bench_compare_disk_strict_chain_summary.step.dependOn(&bench_compare_disk_strict_chain_artifacts.step);
    bench_compare_disk_strict_chain_step.dependOn(&bench_compare_disk_strict_chain_summary.step);

    const bench_compare_memory_strict_chain = addBenchCompareStep(b, db_indexed_memory_bench, sqlite_indexed_memory_bench, bench_compare_proof_runs, true, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg, "memory indexed ERP", "db_erp_indexed_memory", "sqlite_erp_indexed_memory");
    bench_compare_memory_strict_chain.step.dependOn(&install_bench_compare.step);
    bench_compare_memory_strict_chain.step.dependOn(&benchmark_artifacts.step);
    const bench_compare_memory_strict_chain_artifacts = addBenchmarkArtifactGuardStep(b, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_memory_strict_chain_artifacts.step.dependOn(&bench_compare_memory_strict_chain.step);
    const bench_compare_memory_strict_chain_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'bench-compare-memory-strict-chain passed: runs={d} memory strict combined append proof and protected artifact guard completed'", .{bench_compare_proof_runs}),
    });
    bench_compare_memory_strict_chain_summary.step.dependOn(&bench_compare_memory_strict_chain_artifacts.step);
    bench_compare_memory_strict_chain_step.dependOn(&bench_compare_memory_strict_chain_summary.step);

    const bench_compare_proof_disk = addBenchCompareStep(b, db_indexed_write_bench, sqlite_indexed_write_bench, bench_compare_proof_runs, false, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg, "disk indexed ERP", "db_erp_indexed", "sqlite_erp_indexed");
    bench_compare_proof_disk.step.dependOn(&install_bench_compare.step);
    bench_compare_proof_disk.step.dependOn(&benchmark_artifacts.step);
    bench_compare_proof_step.dependOn(&bench_compare_proof_disk.step);

    const bench_compare_proof_memory = addBenchCompareStep(b, db_indexed_memory_bench, sqlite_indexed_memory_bench, bench_compare_proof_runs, false, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg, "memory indexed ERP", "db_erp_indexed_memory", "sqlite_erp_indexed_memory");
    bench_compare_proof_memory.step.dependOn(&install_bench_compare.step);
    bench_compare_proof_memory.step.dependOn(&bench_compare_proof_disk.step);
    bench_compare_proof_step.dependOn(&bench_compare_proof_memory.step);

    const bench_compare_proof_concurrent = addBenchCompareConcurrentStep(b, db_concurrent_bench, db_coltx_concurrent_bench, sqlite_concurrent_bench, bench_compare_proof_runs, true, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_proof_concurrent.step.dependOn(&install_bench_compare.step);
    bench_compare_proof_concurrent.step.dependOn(&bench_compare_proof_memory.step);
    const bench_compare_proof_artifacts = addBenchmarkArtifactGuardStep(b, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_proof_artifacts.step.dependOn(&bench_compare_proof_concurrent.step);
    const bench_compare_proof_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'bench-compare-proof passed: runs={d} disk/memory proof report plus strict concurrent insert and protected artifact guard completed'", .{bench_compare_proof_runs}),
    });
    bench_compare_proof_summary.step.dependOn(&bench_compare_proof_artifacts.step);
    bench_compare_proof_step.dependOn(&bench_compare_proof_summary.step);

    const bench_compare_proof_strict_disk = addBenchCompareStep(b, db_indexed_write_bench, sqlite_indexed_write_bench, bench_compare_proof_runs, true, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg, "disk indexed ERP", "db_erp_indexed", "sqlite_erp_indexed");
    bench_compare_proof_strict_disk.step.dependOn(&install_bench_compare.step);
    bench_compare_proof_strict_disk.step.dependOn(&benchmark_artifacts.step);

    const bench_compare_proof_strict_memory = addBenchCompareStep(b, db_indexed_memory_bench, sqlite_indexed_memory_bench, bench_compare_proof_runs, true, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg, "memory indexed ERP", "db_erp_indexed_memory", "sqlite_erp_indexed_memory");
    bench_compare_proof_strict_memory.step.dependOn(&install_bench_compare.step);
    bench_compare_proof_strict_memory.step.dependOn(&bench_compare_proof_strict_disk.step);

    const bench_compare_proof_strict_concurrent = addBenchCompareConcurrentStep(b, db_concurrent_bench, db_coltx_concurrent_bench, sqlite_concurrent_bench, bench_compare_proof_runs, true, bench_compare_home, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_proof_strict_concurrent.step.dependOn(&install_bench_compare.step);
    bench_compare_proof_strict_concurrent.step.dependOn(&bench_compare_proof_strict_memory.step);
    const bench_compare_proof_strict_artifacts = addBenchmarkArtifactGuardStep(b, benchmark_run_lock, lock_wait_seconds_arg);
    bench_compare_proof_strict_artifacts.step.dependOn(&bench_compare_proof_strict_concurrent.step);
    const bench_compare_proof_strict_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'bench-compare-proof-strict-chain passed: runs={d} strict disk/memory combined append proof plus strict concurrent insert and protected artifact guard completed'", .{bench_compare_proof_runs}),
    });
    bench_compare_proof_strict_summary.step.dependOn(&bench_compare_proof_strict_artifacts.step);
    bench_compare_proof_strict_chain_step.dependOn(&bench_compare_proof_strict_summary.step);

    const sqlite_proof_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'sqlite-proof passed: sqlite-audit plus runs={d} disk/memory/concurrent performance proof completed; disk combined append remains report-only unless strict-chain is explicitly requested'", .{bench_compare_proof_runs}),
    });
    sqlite_proof_summary.step.dependOn(&sqlite_audit_summary.step);
    sqlite_proof_summary.step.dependOn(&bench_compare_proof_summary.step);
    sqlite_proof_step.dependOn(&sqlite_proof_summary.step);

    const sqlite_proof_strict_chain_summary = b.addSystemCommand(&.{
        "bash",
        "-c",
        b.fmt("printf '%s\n' 'sqlite-proof-strict-chain passed: sqlite-audit plus runs={d} strict disk/memory combined append proof and strict concurrent insert completed'", .{bench_compare_proof_runs}),
    });
    sqlite_proof_strict_chain_summary.step.dependOn(&sqlite_audit_summary.step);
    sqlite_proof_strict_chain_summary.step.dependOn(&bench_compare_proof_strict_summary.step);
    sqlite_proof_strict_chain_step.dependOn(&sqlite_proof_strict_chain_summary.step);
}

fn requirePositiveOddRunCount(name: []const u8, value: u32) void {
    if (value == 0 or value % 2 == 0) {
        std.log.err("{s} must be a positive odd run count, got {d}", .{ name, value });
        std.process.exit(1);
    }
}

fn addBenchmarkArtifactGuardStep(b: *std.Build, benchmark_run_lock: []const u8, lock_wait_seconds_arg: []const u8) *std.Build.Step.Run {
    const cmd = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, benchmark_run_lock, "bash", "tests/check_benchmark_artifacts.sh" });
    cmd.addFileInput(b.path("tests/check_benchmark_artifacts.sh"));
    return cmd;
}

fn addDevInstallStep(
    b: *std.Build,
    sa_bin: []const u8,
    plugins_home: []const u8,
    plugins_home_lock: []const u8,
    lock_wait_seconds_arg: []const u8,
    lib: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const install = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, plugins_home_lock, sa_bin, "plugin", "install", "--dev", "." });
    install.setEnvironmentVariable("SA_PLUGINS_HOME", plugins_home);
    install.setEnvironmentVariable("SA_PLUGIN_DEV", "1");
    install.addFileInput(b.path("sap.json"));
    install.addFileInput(b.path("db.sai"));
    install.addFileInput(b.path("db.sal"));
    install.addFileInput(lib.getEmittedBin());
    install.step.dependOn(b.getInstallStep());
    return install;
}

fn addSaBenchStep(
    b: *std.Build,
    bench_step: *std.Build.Step,
    sa_bin: []const u8,
    plugins_home: []const u8,
    plugins_home_lock: []const u8,
    lock_wait_seconds_arg: []const u8,
    install_step: *std.Build.Step,
    source_rel: []const u8,
    out_name: []const u8,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, plugins_home_lock, sa_bin, "build-exe", source_rel });
    cmd.setEnvironmentVariable("SA_PLUGINS_HOME", plugins_home);
    cmd.setEnvironmentVariable("SA_PLUGIN_DEV", "1");
    cmd.addFileInput(b.path(source_rel));
    cmd.addFileInput(b.path("benchmark_test/db.sai"));
    cmd.addFileInput(b.path("benchmark_test/db.sal"));
    cmd.addArg("-o");
    const out = cmd.addOutputFileArg(out_name);
    cmd.addArg("--no-incremental");
    cmd.step.dependOn(install_step);
    bench_step.dependOn(&cmd.step);
    return out;
}

fn addSaSmokeStep(
    b: *std.Build,
    sa_bin: []const u8,
    plugins_home: []const u8,
    plugins_home_lock: []const u8,
    lock_wait_seconds_arg: []const u8,
    install_step: *std.Build.Step,
    source_rel: []const u8,
    out_name: []const u8,
) *std.Build.Step.Run {
    const build_cmd = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, plugins_home_lock, sa_bin, "build-exe", source_rel });
    build_cmd.setEnvironmentVariable("SA_PLUGINS_HOME", plugins_home);
    build_cmd.setEnvironmentVariable("SA_PLUGIN_DEV", "1");
    build_cmd.addFileInput(b.path(source_rel));
    build_cmd.addFileInput(b.path("benchmark_test/db.sai"));
    build_cmd.addFileInput(b.path("benchmark_test/db.sal"));
    build_cmd.addArg("-o");
    const out = build_cmd.addOutputFileArg(out_name);
    build_cmd.addArg("--no-incremental");
    build_cmd.step.dependOn(install_step);

    const script =
        \\
        \\set -euo pipefail
        \\exe="$1"
        \\tmp="$(mktemp -d)"
        \\trap 'rm -rf "$tmp"' EXIT
        \\(cd "$tmp" && "$exe")
    ;
    const run_cmd = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, plugins_home_lock, "bash", "-c", script, "sa-abi-smoke" });
    run_cmd.addFileArg(out);
    run_cmd.setEnvironmentVariable("SA_PLUGINS_HOME", plugins_home);
    run_cmd.setEnvironmentVariable("SA_PLUGIN_DEV", "1");
    run_cmd.step.dependOn(&build_cmd.step);
    return run_cmd;
}

fn addSqliteStdArchiveStep(b: *std.Build, sa_std_lib: []const u8) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        "bash",
        "-c",
        \\
        \\set -euo pipefail
        \\src="$1"
        \\out="$2"
        \\work="$(dirname "$out")/sqlite_link_std_work"
        \\trap 'rm -rf "$work"' EXIT
        \\rm -rf "$work"
        \\mkdir -p "$work"
        \\if ! (cd "$work" && ar x "$src" 2> ar.stderr); then
        \\  cat "$work/ar.stderr" >&2
        \\  exit 1
        \\fi
        \\grep -v 'illegal output pathname for archive member' "$work/ar.stderr" >&2 || true
        \\for obj in "$work"/*.o; do
        \\  objcopy \
        \\    --redefine-sym sqlite3_prepare=sa_std_stub_sqlite3_prepare \
        \\    --redefine-sym sqlite3_step=sa_std_stub_sqlite3_step \
        \\    --redefine-sym sqlite3_finalize=sa_std_stub_sqlite3_finalize \
        \\    "$obj"
        \\done
        \\(cd "$work" && ar rcs "$out" *.o)
        ,
        "sqlite-std-archive",
    });
    cmd.addFileInput(.{ .cwd_relative = sa_std_lib });
    cmd.addArg(sa_std_lib);
    const archive = cmd.addOutputFileArg("libsa_std_no_sqlite_stub.a");
    return archive;
}

fn addSqliteBenchStep(
    b: *std.Build,
    bench_step: *std.Build.Step,
    sa_bin: []const u8,
    sqlite_std_archive: std.Build.LazyPath,
    sqlite_lib: []const u8,
    source_rel: []const u8,
    out_name: []const u8,
) std.Build.LazyPath {
    const obj_name = b.fmt("{s}.o", .{out_name});
    const build_obj = b.addSystemCommand(&.{ sa_bin, "build-obj", source_rel });
    build_obj.addFileInput(b.path(source_rel));
    build_obj.addArg("-o");
    const obj = build_obj.addOutputFileArg(obj_name);
    build_obj.addArg("--no-incremental");

    const link = b.addSystemCommand(&.{ "zig", "cc", "-O1" });
    link.addFileArg(obj);
    link.addFileArg(sqlite_std_archive);
    link.addFileInput(.{ .cwd_relative = sqlite_lib });
    link.addArg(sqlite_lib);
    if (std.fs.path.dirname(sqlite_lib)) |sqlite_dir| {
        link.addArg(b.fmt("-Wl,-rpath,{s}", .{sqlite_dir}));
    }
    link.addArg("-o");
    const out = link.addOutputFileArg(out_name);
    link.step.dependOn(&build_obj.step);
    bench_step.dependOn(&link.step);
    return out;
}

fn addBenchCompareStep(
    b: *std.Build,
    db_bench: std.Build.LazyPath,
    sqlite_bench: std.Build.LazyPath,
    runs: u32,
    strict_chain: bool,
    smoke_home: []const u8,
    benchmark_run_lock: []const u8,
    lock_wait_seconds_arg: []const u8,
    label: []const u8,
    db_prefix: []const u8,
    sqlite_prefix: []const u8,
) *std.Build.Step.Run {
    const script =
        \\
        \\import os
        \\import shutil
        \\import subprocess
        \\import sys
        \\import tempfile
        \\
        \\db_bench, sqlite_bench, runs_s, strict_chain_s, suite_label, db_prefix, sqlite_prefix = sys.argv[1:8]
        \\runs = int(runs_s)
        \\if runs <= 0 or runs % 2 == 0:
        \\    raise SystemExit("benchmark compare run count must be positive odd")
        \\if strict_chain_s not in ("0", "1"):
        \\    raise SystemExit("benchmark compare strict-chain flag must be 0 or 1")
        \\strict_chain = strict_chain_s == "1"
        \\
        \\def parse(output):
        \\    values = {}
        \\    for line in output.splitlines():
        \\        if "=" not in line:
        \\            continue
        \\        key, raw = line.split("=", 1)
        \\        if key in values:
        \\            raise SystemExit(f"benchmark output duplicate metric: {key}")
        \\        try:
        \\            values[key] = int(raw)
        \\        except ValueError:
        \\            raise SystemExit(f"benchmark output invalid integer metric: {key}={raw}")
        \\        if values[key] < 0:
        \\            raise SystemExit(f"benchmark output negative metric: {key}={values[key]}")
        \\    return values
        \\
        \\def clean_roots():
        \\    shutil.rmtree("benchmark_test/.bench_erp_indexed_db", ignore_errors=True)
        \\
        \\def run_bench(path, env, cwd):
        \\    clean_roots()
        \\    completed = subprocess.run([path], cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        \\    if completed.stderr:
        \\        sys.stderr.write(completed.stderr)
        \\    if completed.returncode != 0:
        \\        if completed.stdout:
        \\            sys.stderr.write(completed.stdout)
        \\        raise SystemExit(f"benchmark failed: {path} exit={completed.returncode}")
        \\    return parse(completed.stdout)
        \\
        \\env = os.environ.copy()
        \\env["SA_PLUGIN_DEV"] = "1"
        \\env["SA_DB_UNSAFE_NO_SYNC"] = "1"
        \\try:
        \\    repo_cwd = os.getcwd()
        \\    db_samples = [run_bench(db_bench, env, repo_cwd) for _ in range(runs)]
        \\    with tempfile.TemporaryDirectory(prefix="sa-db-sqlite-control-") as sqlite_cwd:
        \\        sqlite_samples = [run_bench(sqlite_bench, env, sqlite_cwd) for _ in range(runs)]
        \\
        \\    expected_rows = {
        \\        "indexed_order_rows": 8448,
        \\        "indexed_line_rows": 33792,
        \\        "indexed_invoice_rows": 8448,
        \\    }
        \\    def require_keys(samples, keys, label):
        \\        for idx, sample in enumerate(samples):
        \\            missing = [key for key in keys if key not in sample]
        \\            if missing:
        \\                raise SystemExit(f"bench-compare failed: {suite_label} {label} sample {idx + 1} missing metrics: {', '.join(missing)}")
        \\
        \\    def require_positive_keys(samples, keys, label):
        \\        for idx, sample in enumerate(samples):
        \\            non_positive = [key for key in keys if sample[key] <= 0]
        \\            if non_positive:
        \\                raise SystemExit(f"bench-compare failed: {suite_label} {label} sample {idx + 1} non-positive timing metrics: {', '.join(non_positive)}")
        \\
        \\    row_keys = list(expected_rows.keys())
        \\    db_timing_keys = [
        \\        f"{db_prefix}_init_ns",
        \\        f"{db_prefix}_baseline_ns",
        \\        f"{db_prefix}_build_ns",
        \\        f"{db_prefix}_tx_append_ns",
        \\        f"{db_prefix}_coltx_append_ns",
        \\        f"{db_prefix}_verify_ns",
        \\    ]
        \\    sqlite_timing_keys = [
        \\        f"{sqlite_prefix}_init_ns",
        \\        f"{sqlite_prefix}_baseline_ns",
        \\        f"{sqlite_prefix}_build_ns",
        \\        f"{sqlite_prefix}_append_ns",
        \\        f"{sqlite_prefix}_verify_ns",
        \\    ]
        \\    require_keys(db_samples, db_timing_keys + row_keys, "db")
        \\    require_keys(sqlite_samples, sqlite_timing_keys + row_keys, "sqlite")
        \\    require_positive_keys(db_samples, db_timing_keys, "db")
        \\    require_positive_keys(sqlite_samples, sqlite_timing_keys, "sqlite")
        \\    for sample in db_samples + sqlite_samples:
        \\        for key, expected in expected_rows.items():
        \\            if sample.get(key) != expected:
        \\                raise SystemExit(f"{key} expected {expected}, got {sample.get(key)}")
        \\
        \\    def observed_median(values):
        \\        return sorted(values)[len(values) // 2]
        \\
        \\    def stat(samples, key):
        \\        values = [sample[key] for sample in samples]
        \\        return (min(values), observed_median(values), max(values))
        \\
        \\    def stat_sum(samples, left_key, right_key):
        \\        values = [sample[left_key] + sample[right_key] for sample in samples]
        \\        return (min(values), observed_median(values), max(values))
        \\
        \\    def fmt_stat(ns):
        \\        return f"{ns[1] / 1_000_000:.3f} ms [{ns[0] / 1_000_000:.3f}, {ns[2] / 1_000_000:.3f}]"
        \\
        \\    db_init_stat = stat(db_samples, f"{db_prefix}_init_ns")
        \\    db_baseline_stat = stat(db_samples, f"{db_prefix}_baseline_ns")
        \\    db_build_stat = stat(db_samples, f"{db_prefix}_build_ns")
        \\    db_tx_stat = stat(db_samples, f"{db_prefix}_tx_append_ns")
        \\    db_coltx_stat = stat(db_samples, f"{db_prefix}_coltx_append_ns")
        \\    db_verify_stat = stat(db_samples, f"{db_prefix}_verify_ns")
        \\    db_chain_stat = stat_sum(db_samples, f"{db_prefix}_tx_append_ns", f"{db_prefix}_coltx_append_ns")
        \\
        \\    sqlite_init_stat = stat(sqlite_samples, f"{sqlite_prefix}_init_ns")
        \\    sqlite_baseline_stat = stat(sqlite_samples, f"{sqlite_prefix}_baseline_ns")
        \\    sqlite_build_stat = stat(sqlite_samples, f"{sqlite_prefix}_build_ns")
        \\    sqlite_append_stat = stat(sqlite_samples, f"{sqlite_prefix}_append_ns")
        \\    sqlite_verify_stat = stat(sqlite_samples, f"{sqlite_prefix}_verify_ns")
        \\
        \\    hard_checks = [
        \\        ("init", db_init_stat, sqlite_init_stat),
        \\        ("baseline", db_baseline_stat, sqlite_baseline_stat),
        \\        ("build", db_build_stat, sqlite_build_stat),
        \\        ("tx append", db_tx_stat, sqlite_append_stat),
        \\        ("coltx append", db_coltx_stat, sqlite_append_stat),
        \\        ("verify", db_verify_stat, sqlite_verify_stat),
        \\    ]
        \\    report_checks = hard_checks + [("total append chain", db_chain_stat, sqlite_append_stat)]
        \\    for check_label, db_stat, sqlite_stat in hard_checks:
        \\        if db_stat[1] >= sqlite_stat[1]:
        \\            raise SystemExit(f"bench-compare failed: {suite_label} {check_label}: db={db_stat[1]} sqlite={sqlite_stat[1]}")
        \\    if strict_chain and db_chain_stat[1] >= sqlite_append_stat[1]:
        \\        raise SystemExit(f"bench-compare failed: {suite_label} total append chain: db={db_chain_stat[1]} sqlite={sqlite_append_stat[1]}")
        \\
        \\    print(f"bench-compare {suite_label} runs={runs} strict_chain={strict_chain}")
        \\    for check_label, db_stat, sqlite_stat in report_checks:
        \\        status = "PASS" if db_stat[1] < sqlite_stat[1] else "WARN"
        \\        margin = sqlite_stat[1] - db_stat[1]
        \\        print(f"{check_label}: {status} db={fmt_stat(db_stat)} sqlite={fmt_stat(sqlite_stat)} margin={margin / 1_000_000:.3f} ms")
        \\finally:
        \\    clean_roots()
    ;
    const cmd = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, benchmark_run_lock, "python3", "-c", script });
    cmd.addFileArg(db_bench);
    cmd.addFileArg(sqlite_bench);
    cmd.addArg(b.fmt("{d}", .{runs}));
    cmd.addArg(if (strict_chain) "1" else "0");
    cmd.addArg(label);
    cmd.addArg(db_prefix);
    cmd.addArg(sqlite_prefix);
    cmd.setEnvironmentVariable("SA_PLUGINS_HOME", smoke_home);
    cmd.setEnvironmentVariable("SA_PLUGIN_DEV", "1");
    cmd.setEnvironmentVariable("SA_DB_UNSAFE_NO_SYNC", "1");
    return cmd;
}

fn addBenchCompareConcurrentStep(
    b: *std.Build,
    db_raw_bench: std.Build.LazyPath,
    db_coltx_bench: std.Build.LazyPath,
    sqlite_bench: std.Build.LazyPath,
    runs: u32,
    strict_insert: bool,
    smoke_home: []const u8,
    benchmark_run_lock: []const u8,
    lock_wait_seconds_arg: []const u8,
) *std.Build.Step.Run {
    const script =
        \\
        \\import os
        \\import shutil
        \\import subprocess
        \\import sys
        \\import tempfile
        \\
        \\db_raw_bench, db_coltx_bench, sqlite_bench, runs_s, strict_insert_s = sys.argv[1:6]
        \\runs = int(runs_s)
        \\if runs <= 0 or runs % 2 == 0:
        \\    raise SystemExit("benchmark compare run count must be positive odd")
        \\if strict_insert_s not in ("0", "1"):
        \\    raise SystemExit("benchmark compare strict-insert flag must be 0 or 1")
        \\strict_insert = strict_insert_s == "1"
        \\repo_cwd = os.getcwd()
        \\roots = [
        \\    os.path.join(repo_cwd, "benchmark_test/.bench_raw"),
        \\    os.path.join(repo_cwd, "benchmark_test/.bench_coltx"),
        \\    os.path.join(repo_cwd, "benchmark_test/.bench_sqlite"),
        \\]
        \\
        \\def parse(output):
        \\    values = {}
        \\    for line in output.splitlines():
        \\        if "=" not in line:
        \\            continue
        \\        key, raw = line.split("=", 1)
        \\        if key in values:
        \\            raise SystemExit(f"benchmark output duplicate metric: {key}")
        \\        try:
        \\            values[key] = int(raw)
        \\        except ValueError:
        \\            raise SystemExit(f"benchmark output invalid integer metric: {key}={raw}")
        \\        if values[key] < 0:
        \\            raise SystemExit(f"benchmark output negative metric: {key}={values[key]}")
        \\    return values
        \\
        \\def observed_median(values):
        \\    return sorted(values)[len(values) // 2]
        \\
        \\def stat(samples, key):
        \\    values = [sample[key] for sample in samples]
        \\    return (min(values), observed_median(values), max(values))
        \\
        \\def fmt_stat(ns):
        \\    return f"{ns[1] / 1_000_000:.3f} ms [{ns[0] / 1_000_000:.3f}, {ns[2] / 1_000_000:.3f}]"
        \\
        \\def clean_roots():
        \\    for root in roots:
        \\        shutil.rmtree(root, ignore_errors=True)
        \\
        \\def backup_roots(backup_dir):
        \\    for root in roots:
        \\        if os.path.exists(root):
        \\            shutil.copytree(root, os.path.join(backup_dir, os.path.basename(root)), symlinks=True)
        \\
        \\def restore_roots(backup_dir):
        \\    for root in roots:
        \\        shutil.rmtree(root, ignore_errors=True)
        \\        saved = os.path.join(backup_dir, os.path.basename(root))
        \\        if os.path.exists(saved):
        \\            shutil.copytree(saved, root, symlinks=True)
        \\
        \\def run_bench(path, env):
        \\    clean_roots()
        \\    completed = subprocess.run([path], cwd=repo_cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        \\    if completed.stderr:
        \\        sys.stderr.write(completed.stderr)
        \\    if completed.returncode != 0:
        \\        if completed.stdout:
        \\            sys.stderr.write(completed.stdout)
        \\        raise SystemExit(f"benchmark failed: {path} exit={completed.returncode}")
        \\    return parse(completed.stdout)
        \\
        \\def require(sample, key, expected):
        \\    actual = sample.get(key)
        \\    if actual != expected:
        \\        raise SystemExit(f"{key} expected {expected}, got {actual}")
        \\
        \\def require_keys(samples, keys, label):
        \\    for idx, sample in enumerate(samples):
        \\        missing = [key for key in keys if key not in sample]
        \\        if missing:
        \\            raise SystemExit(f"bench-compare-concurrent failed: {label} sample {idx + 1} missing metrics: {', '.join(missing)}")
        \\
        \\def require_positive_keys(samples, keys, label):
        \\    for idx, sample in enumerate(samples):
        \\        non_positive = [key for key in keys if sample[key] <= 0]
        \\        if non_positive:
        \\            raise SystemExit(f"bench-compare-concurrent failed: {label} sample {idx + 1} non-positive timing metrics: {', '.join(non_positive)}")
        \\
        \\def require_bool_keys(samples, keys, label):
        \\    for idx, sample in enumerate(samples):
        \\        invalid = [key for key in keys if sample[key] not in (0, 1)]
        \\        if invalid:
        \\            raise SystemExit(f"bench-compare-concurrent failed: {label} sample {idx + 1} non-boolean status metrics: {', '.join(invalid)}")
        \\
        \\def require_insert_consistency(samples, ok_key, rows_key, expected_rows, label):
        \\    for idx, sample in enumerate(samples):
        \\        ok = sample[ok_key]
        \\        rows = sample[rows_key]
        \\        if rows > expected_rows:
        \\            raise SystemExit(f"bench-compare-concurrent failed: {label} sample {idx + 1} rows exceed expected insert count: {rows_key}={rows} expected={expected_rows}")
        \\        if ok == 1 and rows != expected_rows:
        \\            raise SystemExit(f"bench-compare-concurrent failed: {label} sample {idx + 1} reports ok=1 but incomplete rows: {rows_key}={rows} expected={expected_rows}")
        \\        if ok == 0 and rows == expected_rows:
        \\            raise SystemExit(f"bench-compare-concurrent failed: {label} sample {idx + 1} reports ok=0 but full rows: {rows_key}={rows}")
        \\
        \\def print_check(label, db_stat, sqlite_stat):
        \\    status = "PASS" if db_stat[1] < sqlite_stat[1] else "FAIL"
        \\    margin = sqlite_stat[1] - db_stat[1]
        \\    print(f"{label}: {status} db={fmt_stat(db_stat)} sqlite={fmt_stat(sqlite_stat)} margin={margin / 1_000_000:.3f} ms")
        \\    if db_stat[1] >= sqlite_stat[1]:
        \\        raise SystemExit(f"bench-compare-concurrent failed: {label}: db={db_stat[1]} sqlite={sqlite_stat[1]}")
        \\
        \\def print_report(label, db_stat, sqlite_stat, db_ok_count):
        \\    status = "PASS" if db_ok_count == runs and db_stat[1] < sqlite_stat[1] else "WARN"
        \\    margin = sqlite_stat[1] - db_stat[1]
        \\    print(f"{label}: {status} db={fmt_stat(db_stat)} sqlite={fmt_stat(sqlite_stat)} margin={margin / 1_000_000:.3f} ms db_ok={db_ok_count}/{runs}")
        \\    if strict_insert and status != "PASS":
        \\        raise SystemExit(f"bench-compare-concurrent failed: {label}: db_ok={db_ok_count}/{runs} db={db_stat[1]} sqlite={sqlite_stat[1]}")
        \\
        \\env = os.environ.copy()
        \\env["SA_PLUGIN_DEV"] = "1"
        \\env["SA_DB_UNSAFE_NO_SYNC"] = "1"
        \\with tempfile.TemporaryDirectory(prefix="sa-db-concurrent-roots-") as backup_dir:
        \\    backup_roots(backup_dir)
        \\    try:
        \\        raw_samples = [run_bench(db_raw_bench, env) for _ in range(runs)]
        \\        coltx_samples = [run_bench(db_coltx_bench, env) for _ in range(runs)]
        \\        sqlite_samples = [run_bench(sqlite_bench, env) for _ in range(runs)]
        \\        db_required_keys = [
        \\            "db_serial_query_ok",
        \\            "db_concurrent_query_ok",
        \\            "db_serial_query_ns",
        \\            "db_concurrent_query_ns",
        \\            "db_concurrent_insert_ns",
        \\            "db_concurrent_insert_ok",
        \\            "db_concurrent_insert_rows",
        \\        ]
        \\        sqlite_required_keys = [
        \\            "sqlite_serial_query_ok",
        \\            "sqlite_concurrent_query_ok",
        \\            "sqlite_concurrent_insert_ok",
        \\            "sqlite_concurrent_insert_rows",
        \\            "sqlite_serial_query_ns",
        \\            "sqlite_concurrent_query_ns",
        \\            "sqlite_concurrent_insert_ns",
        \\        ]
        \\        require_keys(raw_samples, db_required_keys, "raw db")
        \\        require_keys(coltx_samples, db_required_keys, "coltx db")
        \\        require_keys(sqlite_samples, sqlite_required_keys, "sqlite")
        \\        db_timing_keys = ["db_serial_query_ns", "db_concurrent_query_ns", "db_concurrent_insert_ns"]
        \\        sqlite_timing_keys = ["sqlite_serial_query_ns", "sqlite_concurrent_query_ns", "sqlite_concurrent_insert_ns"]
        \\        db_bool_keys = ["db_serial_query_ok", "db_concurrent_query_ok", "db_concurrent_insert_ok"]
        \\        sqlite_bool_keys = ["sqlite_serial_query_ok", "sqlite_concurrent_query_ok", "sqlite_concurrent_insert_ok"]
        \\        require_bool_keys(raw_samples, db_bool_keys, "raw db")
        \\        require_bool_keys(coltx_samples, db_bool_keys, "coltx db")
        \\        require_bool_keys(sqlite_samples, sqlite_bool_keys, "sqlite")
        \\        require_insert_consistency(raw_samples, "db_concurrent_insert_ok", "db_concurrent_insert_rows", 50000, "raw db")
        \\        require_insert_consistency(coltx_samples, "db_concurrent_insert_ok", "db_concurrent_insert_rows", 50000, "coltx db")
        \\        require_insert_consistency(sqlite_samples, "sqlite_concurrent_insert_ok", "sqlite_concurrent_insert_rows", 50000, "sqlite")
        \\        require_positive_keys(raw_samples, db_timing_keys, "raw db")
        \\        require_positive_keys(coltx_samples, db_timing_keys, "coltx db")
        \\        require_positive_keys(sqlite_samples, sqlite_timing_keys, "sqlite")
        \\        for sample in raw_samples + coltx_samples:
        \\            require(sample, "db_serial_query_ok", 1)
        \\            require(sample, "db_concurrent_query_ok", 1)
        \\        for sample in sqlite_samples:
        \\            require(sample, "sqlite_serial_query_ok", 1)
        \\            require(sample, "sqlite_concurrent_query_ok", 1)
        \\            require(sample, "sqlite_concurrent_insert_ok", 1)
        \\            require(sample, "sqlite_concurrent_insert_rows", 50000)
        \\        raw_insert_ok_count = sum(1 for sample in raw_samples if sample.get("db_concurrent_insert_ok") == 1 and sample.get("db_concurrent_insert_rows") == 50000)
        \\        coltx_insert_ok_count = sum(1 for sample in coltx_samples if sample.get("db_concurrent_insert_ok") == 1 and sample.get("db_concurrent_insert_rows") == 50000)
        \\
        \\        raw_serial = stat(raw_samples, "db_serial_query_ns")
        \\        raw_query = stat(raw_samples, "db_concurrent_query_ns")
        \\        raw_insert = stat(raw_samples, "db_concurrent_insert_ns")
        \\        coltx_serial = stat(coltx_samples, "db_serial_query_ns")
        \\        coltx_query = stat(coltx_samples, "db_concurrent_query_ns")
        \\        coltx_insert = stat(coltx_samples, "db_concurrent_insert_ns")
        \\        sqlite_serial = stat(sqlite_samples, "sqlite_serial_query_ns")
        \\        sqlite_query = stat(sqlite_samples, "sqlite_concurrent_query_ns")
        \\        sqlite_insert = stat(sqlite_samples, "sqlite_concurrent_insert_ns")
        \\
        \\        print(f"bench-compare concurrent runs={runs} strict_insert={strict_insert}")
        \\        print_check("raw serial query", raw_serial, sqlite_serial)
        \\        print_check("coltx serial query", coltx_serial, sqlite_serial)
        \\        print_check("raw concurrent query", raw_query, sqlite_query)
        \\        print_check("coltx concurrent query", coltx_query, sqlite_query)
        \\        print_report("raw concurrent insert", raw_insert, sqlite_insert, raw_insert_ok_count)
        \\        print_report("coltx concurrent insert", coltx_insert, sqlite_insert, coltx_insert_ok_count)
        \\    finally:
        \\        restore_roots(backup_dir)
    ;
    const cmd = b.addSystemCommand(&.{ "flock", "-w", lock_wait_seconds_arg, benchmark_run_lock, "python3", "-c", script });
    cmd.addFileArg(db_raw_bench);
    cmd.addFileArg(db_coltx_bench);
    cmd.addFileArg(sqlite_bench);
    cmd.addArg(b.fmt("{d}", .{runs}));
    cmd.addArg(if (strict_insert) "1" else "0");
    cmd.setEnvironmentVariable("SA_PLUGINS_HOME", smoke_home);
    cmd.setEnvironmentVariable("SA_PLUGIN_DEV", "1");
    cmd.setEnvironmentVariable("SA_DB_UNSAFE_NO_SYNC", "1");
    return cmd;
}
