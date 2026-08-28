import io

path = "build.zig"
with io.open(path, "r", encoding="utf-8") as f:
    src = f.read()

anchor = """    stageDbRuntimeNextToOut(b, bench_step, cmd, out, plugins_home);
    return out;
"""
assert src.count(anchor) == 1, "anchor not found exactly once"

inject = """    stageDbRuntimeNextToOut(b, bench_step, cmd, out, plugins_home);
    if (b.graph.host.result.os.tag == .windows) {
        const enlarge_stack = b.addSystemCommand(&.{ "bash", "-c", "set -euo pipefail; out='$1'; eb='${EDITBIN:-editbin}'; if command -v '$eb' >/dev/null 2>&1; then '$eb' /STACK:16777216 '$out'; fi" });
        enlarge_stack.addFileArg(out);
        enlarge_stack.step.dependOn(&cmd.step);
        bench_step.dependOn(&enlarge_stack.step);
    }
    return out;
"""

src = src.replace(anchor, inject)
with io.open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("patched build.zig addSaBenchStep")
