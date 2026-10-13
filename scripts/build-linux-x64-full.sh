#!/usr/bin/env bash
set -euo pipefail

readonly task_jobs="${LOBUN_V8_BUILD_JOBS-2}"
if [[ ! "$task_jobs" =~ ^([1-9]|1[0-6])$ ]]; then
  printf '%s\n' 'LOBUN_V8_BUILD_JOBS must be an integer from 1 to 16' >&2
  exit 1
fi

# One manual producer, without shared V8 cache or dependency installation.
readonly task_version=15.3.76.24
readonly task_revision=107d9154d9d944f722c9f6af126849217660709c
readonly task_depot_revision=2fd34a8813b6f34336aad40976cc4223768177f8
readonly task_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly task_work="${RUNNER_TEMP:?RUNNER_TEMP is required}/v8-full-build"
readonly task_source="$task_work/v8"
readonly task_out="$task_source/out.gn/linux.x64.release"
readonly task_seed="$task_work/seed"
readonly task_info="$task_seed/v8/build-info"
readonly task_artifact="$task_repo/artifacts/v8-linux-x64-$task_version-full.tar.gz"
# Keep the runner's Ninja; depot_tools also ships a bootstrap-dependent wrapper.
readonly task_ninja="$(command -v ninja)"
test -x "$task_ninja"
test ! -e "$task_work"
test ! -e "$task_artifact"
mkdir -p "$task_work" "$task_info" "$(dirname "$task_artifact")"
df -h "$task_work"
git init "$task_work/depot_tools"
git -C "$task_work/depot_tools" remote add origin https://chromium.googlesource.com/chromium/tools/depot_tools.git
git -C "$task_work/depot_tools" fetch --depth=1 origin "$task_depot_revision"
git -C "$task_work/depot_tools" checkout --detach FETCH_HEAD
test "$(git -C "$task_work/depot_tools" rev-parse HEAD)" = "$task_depot_revision"
export PATH="$task_work/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
export DEPOT_TOOLS_METRICS=0
cat > "$task_work/.gclient" <<'GCLIENT'
solutions = [{
  'name': 'v8',
  'url': 'https://chromium.googlesource.com/v8/v8.git',
  'deps_file': 'DEPS',
  'managed': False,
  'custom_deps': {},
  'custom_vars': {'checkout_rust': True},
}]
target_os = ['linux']
GCLIENT
(
  cd "$task_work"
  gclient sync --no-history --jobs 2 --revision "v8@$task_revision"
)
test "$(git -C "$task_source" rev-parse HEAD)" = "$task_revision"
git -C "$task_source" diff --exit-code
git -C "$task_source" diff --cached --exit-code
python3 - "$task_source/include/v8-version.h" "$task_version" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
names = ['MAJOR_VERSION', 'MINOR_VERSION', 'BUILD_NUMBER', 'PATCH_LEVEL']
version = '.'.join(re.search(r'^#define V8_' + name + r'\s+(\d+)', source, re.M).group(1) for name in names)
if version != sys.argv[2]:
    raise SystemExit('V8 source version mismatch: ' + version)
PY
for task_patch in \
  bun-module-namespace.patch \
  guarded-osr-context.patch \
  15.3-cfunctioninfo-has-receiver-kno.patch \
  15.3-maglev-bounded-native-leaf.patch; do
  git -C "$task_source" apply --check "$task_repo/patches/$task_patch"
  git -C "$task_source" apply "$task_repo/patches/$task_patch"
done
git -C "$task_source" diff --check
mkdir -p "$task_out"
cp "$task_repo/args.linux.x64.gn" "$task_out/args.gn"
cmp "$task_repo/args.linux.x64.gn" "$task_out/args.gn"
cp "$task_out/args.gn" "$task_info/args.gn"
readonly task_clang="$task_source/third_party/llvm-build/Release+Asserts/bin"
readonly task_rust="$task_source/third_party/rust-toolchain/bin/rustc"
readonly task_gn="$task_source/buildtools/linux64/gn"
test -x "$task_clang/clang++"
test -x "$task_rust"
test -x "$task_gn"
{
  printf 'V8_VERSION=%s\nV8_REVISION=%s\nDEPOT_TOOLS_REVISION=%s\n' "$task_version" "$task_revision" "$task_depot_revision"
  printf 'FORK_REVISION=%s\nNINJA_JOBS=%s\nBUILD_TIMEOUT_MINUTES=270\n' "$(git -C "$task_repo" rev-parse HEAD)" "$task_jobs"
  uname -a
  "$task_clang/clang++" --version
  "$task_clang/ld.lld" --version
  "$task_rust" --version
  "$task_gn" --version
  "$task_ninja" --version
} | tee "$task_info/build-info.txt"
(
  cd "$task_source"
  "$task_gn" gen out.gn/linux.x64.release
  "$task_gn" args out.gn/linux.x64.release --list --short > "$task_info/gn-effective-args.txt"
  "$task_gn" desc out.gn/linux.x64.release //:v8_monolith defines > "$task_info/monolith-defines.txt"
  # Compile the namespace port first; the full build reuses these same objects.
  timeout --signal=TERM --kill-after=30s 270m \
    bash -e -u -o pipefail -c '
      "$1" -j"$2" -C out.gn/linux.x64.release \
        obj/v8_base_without_compiler/builtins-object.o \
        obj/v8_base_without_compiler/module.o
      "$1" -j"$2" -C out.gn/linux.x64.release v8_monolith cctest v8_unittests
    ' -- "$task_ninja" "$task_jobs"
)
df -h "$task_work"

# Fixed selectors must exist, and each invocation must actually pass one case.
"$task_out/cctest" --list > "$task_info/cctest-list.txt"
task_native_count=0
run_cctest() {
  local task_case="$1"
  grep -Fxq "**>Test: $task_case" "$task_info/cctest-list.txt"
  timeout --signal=TERM --kill-after=10s 300s "$task_out/cctest" "$task_case" 2>&1 | tee -a "$task_info/native-gates.log"
  printf 'PASS %s\n' "$task_case" | tee -a "$task_info/native-gates.txt"
  task_native_count=$((task_native_count + 1))
}
for task_case in \
  ReduceGuardedOsrContextByNodeIdentity GuardedOsrContextDynamicRecovery \
  ReduceJSLoadContextNoCell0 ReduceJSLoadContextNoCell1 ReduceJSLoadContextNoCell2 ReduceJSLoadContextNoCell3 \
  ReduceJSStoreContextNoCell0 ReduceJSStoreContextNoCell1 ReduceJSStoreContextNoCell2 ReduceJSStoreContextNoCell3 \
  SpecializeJSFunction_ToConstant1 SpecializeJSFunction_ToConstant2 SpecializeJSFunction_ToConstant3 SpecializeJSFunction_ToConstant_uninit; do
  run_cctest "test-js-context-specialization/$task_case"
done
for task_case in \
  FastApiCalls FastApiStackSlot FastApiCallWithAllocationAndGCInC FastApiCallWithAllocationAndGCInJS \
  FastApiCallWithThrowInReentrantCode FastApiCallRecursionWithException FastApiCallRecursionNoException FastApiCallsFromWasm \
  FastApiCallsWithoutReceiver; do
  run_cctest "test-api/$task_case"
done
run_cctest test-cpu-profiler/FastApiCPUProfiler
for task_case in TerminateOnlyV8ThreadFromOtherThread TerminateFromOtherThreadWhileMicrotaskRunning TerminationInInnerTryCall; do
  timeout --signal=TERM --kill-after=10s 300s "$task_out/v8_unittests" \
    "--gtest_filter=ThreadTerminationTest.$task_case" --gtest_color=no | tee "$task_info/termination-$task_case.log"
  grep -Fxq '[  PASSED  ] 1 test.' "$task_info/termination-$task_case.log"
  printf 'PASS ThreadTerminationTest.%s\n' "$task_case" | tee -a "$task_info/native-gates.txt"
  task_native_count=$((task_native_count + 1))
done
test "$task_native_count" -eq 27
for task_case in \
  FastApiBoundedNativeMaglev FastApiBoundedNativeMaglevDeopt FastApiBoundedNativeMaglevTermination; do
  run_cctest "test-api/$task_case"
done
test "$task_native_count" -eq 30
printf 'TOTAL_PASS=%s\n' "$task_native_count" >> "$task_info/native-gates.txt"

# Existing seed paths: the rsp is interpreted from the consumer seed root.
mkdir -p "$task_seed/v8/include" "$task_seed/v8/src" "$task_seed/v8/gen" "$task_seed/v8/rust-rlibs"
cp -a "$task_source/include/." "$task_seed/v8/include/"
cp -a "$task_source/src/." "$task_seed/v8/src/"
cp -a "$task_out/gen/." "$task_seed/v8/gen/"
cp "$task_out/obj/libv8_monolith.a" "$task_seed/v8/libv8_monolith.a"
test -s "$task_seed/v8/libv8_monolith.a"
test -d "$task_out/obj"
test -d "$task_out/local_rustc_sysroot"
(
  cd "$task_out"
  : > "$task_info/rlibs.nul"
  for task_prefix in obj local_rustc_sysroot; do
    find "$task_prefix" -type f -name '*.rlib' -print0 | sort -z >> "$task_info/rlibs.nul"
  done
)
test -s "$task_info/rlibs.nul"
printf '%s\n' '-Wl,--allow-multiple-definition' '-Wl,--start-group' > "$task_seed/v8/rust-rlibs.rsp"
while IFS= read -r -d '' task_rlib; do
  mkdir -p "$task_seed/v8/rust-rlibs/$(dirname "$task_rlib")"
  cp "$task_out/$task_rlib" "$task_seed/v8/rust-rlibs/$task_rlib"
  printf 'v8/rust-rlibs/%s\n' "$task_rlib" >> "$task_seed/v8/rust-rlibs.rsp"
done < "$task_info/rlibs.nul"
printf '%s\n' '-Wl,--end-group' >> "$task_seed/v8/rust-rlibs.rsp"
du -sh "$task_seed" "$task_out"
tar -C "$task_seed" -czf "$task_artifact" v8
test -s "$task_artifact"
df -h "$task_work"
