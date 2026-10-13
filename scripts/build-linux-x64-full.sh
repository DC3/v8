#!/usr/bin/env bash
set -euo pipefail

readonly task_jobs="${LOBUN_V8_BUILD_JOBS-2}"
if [[ ! "$task_jobs" =~ ^([1-9]|1[0-6])$ ]]; then
  printf '%s\n' 'LOBUN_V8_BUILD_JOBS must be an integer from 1 to 16' >&2
  exit 1
fi

# One producer; only explicitly configured local runs reuse prepared inputs.
readonly task_version=15.3.76.24
readonly task_revision=107d9154d9d944f722c9f6af126849217660709c
readonly task_depot_revision=2fd34a8813b6f34336aad40976cc4223768177f8
readonly task_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly task_work="${RUNNER_TEMP:?RUNNER_TEMP is required}/v8-full-build"
task_build="$task_work"
task_cached=false
fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ "$task_work" = /* && "$(realpath -m -- "$task_work")" = "$task_work" ]] || fail 'RUNNER_TEMP must be an absolute canonical directory'
if [[ ${LOBUN_V8_BUILD_CACHE+x} ]]; then
  task_build="$LOBUN_V8_BUILD_CACHE"
  [[ "$task_build" = /* && "$task_build" != / && "$(realpath -m -- "$task_build")" = "$task_build" ]] || fail 'LOBUN_V8_BUILD_CACHE must be an absolute canonical directory'
  for task_boundary in "$task_repo" "$task_work"; do
    case "$task_build/" in "$task_boundary/"*) fail 'cache overlaps checkout or current output';; esac
    case "$task_boundary/" in "$task_build/"*) fail 'cache contains checkout or current output';; esac
  done
  [[ ! -L "$task_build" && ( ! -e "$task_build" || -d "$task_build" ) ]] || fail 'invalid cache directory'
  task_cached=true
fi
readonly task_build task_cached
readonly task_source="$task_build/v8"
readonly task_depot="$task_build/depot_tools"
readonly task_out="$task_source/out.gn/linux.x64.release"
readonly task_seed="$task_work/seed"
readonly task_info="$task_seed/v8/build-info"
readonly task_artifact="$task_repo/artifacts/v8-linux-x64-$task_version-full.tar.gz"
readonly task_state="$task_build/.applied.patch"
readonly task_patch_state="$task_build/.applied-patches"
readonly task_patches=(bun-module-namespace.patch guarded-osr-context.patch 15.3-cfunctioninfo-has-receiver-kno.patch 15.3-maglev-bounded-native-leaf.patch)
readonly task_clang="$task_source/third_party/llvm-build/Release+Asserts/bin"
readonly task_rust="$task_source/third_party/rust-toolchain/bin/rustc"
readonly task_gn="$task_source/buildtools/linux64/gn"
for task_patch in "${task_patches[@]}"; do
  [[ -f "$task_repo/patches/$task_patch" && ! -L "$task_repo/patches/$task_patch" ]] || fail "missing patch input: $task_patch"
done

check_checkout() {
  local task_dir="$1" task_expected="$2" task_head
  [[ -d "$task_dir/.git" && ! -L "$task_dir" && ! -L "$task_dir/.git" ]] || fail "invalid checkout: $task_dir"
  git -C "$task_dir" diff --cached --quiet || fail "staged changes in $task_dir"
  [[ -z "$(git -C "$task_dir" ls-files --others --exclude-standard)" ]] || fail "untracked source in $task_dir"
  task_head="$(git -C "$task_dir" rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ -n "$task_head" ]]; then
    [[ "$task_head" = "$task_expected" ]] || fail "unexpected revision in $task_dir"
  else
    [[ -z "$(git -C "$task_dir" ls-files)" ]] || fail "incomplete nonempty checkout: $task_dir"
  fi
}
source_diff() { git -C "$task_source" diff --no-ext-diff --no-textconv --binary; }
check_dependencies() {
  # gclient evaluates the pinned DEPS graph; do not maintain a second dep list.
  # CIPD/GCS packages and hooks are calibrated by sync on every invocation.
  python3 - "$task_build" "$1" <<'PY'
import json, pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1])
allow_missing = sys.argv[2] == 'allow-missing'
mapping = json.loads(subprocess.check_output([
    'gclient', 'revinfo', '--ignore-dep-type=cipd', '--ignore-dep-type=gcs',
    '--output-json=-'], cwd=root, text=True))
def git(path, *args):
    return subprocess.check_output(['git', '-C', str(path), *args], text=True).strip()
def canonical_url(url):
    return url.rstrip('/').removesuffix('.git')
checkouts = []
for name, entry in mapping.items():
    if name == 'v8' or entry['url'] is None:
        continue  # V8's known patch/index/HEAD were checked separately.
    path = root / name
    if not path.resolve().is_relative_to(root.resolve()):
        raise SystemExit('dependency escapes cache: ' + name)
    if not path.exists():
        if allow_missing:
            continue
        raise SystemExit('missing dependency after sync: ' + name)
    # rev-parse handles both ordinary .git directories and gclient gitfiles,
    # while rejecting an incomplete child that would resolve to a parent repo.
    if pathlib.Path(git(path, 'rev-parse', '--show-toplevel')).resolve() != path.resolve():
        raise SystemExit('not a dependency checkout: ' + name)
    revision = entry['rev']
    if not revision or not re.fullmatch('[0-9a-f]{40}', revision):
        raise SystemExit('dependency is not pinned: ' + name)
    if git(path, 'rev-parse', 'HEAD') != revision:
        raise SystemExit('unexpected dependency revision: ' + name)
    if canonical_url(git(path, 'remote', 'get-url', 'origin')) != canonical_url(entry['url']):
        raise SystemExit('unexpected dependency origin: ' + name)
    for args in [('diff', '--quiet'), ('diff', '--cached', '--quiet')]:
        if subprocess.run(['git', '-C', str(path), *args]).returncode:
            raise SystemExit('modified/staged dependency source: ' + name)
    checkouts.append((name, path))
# Some DEPS checkouts contain another declared Git checkout (for example src/).
# Exclude only independently validated children, then check each child itself.
for name, path in checkouts:
    pathspec = ['.']
    for child_name, child in checkouts:
        if child != path and child.is_relative_to(path):
            pathspec.append(':(top,exclude,literal)' + str(child.relative_to(path)))
    if git(path, 'ls-files', '--others', '--exclude-standard', '-z', '--', *pathspec):
        raise SystemExit('untracked dependency source: ' + name)
PY
}
check_cpp_patch() {
  local task_added task_removed task_path
  git apply --numstat "$1" | while IFS=$'\t' read -r task_added task_removed task_path; do
    case "$task_path" in
      *.cc|*.h) ;;
      *) fail 'cached output only supports C++ source patches; use a new cache for build graph changes';;
    esac
  done
}
gclient_config() {
  cat <<'GCLIENT'
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
}

# Keep the runner's Ninja; depot_tools also ships a bootstrap-dependent wrapper.
readonly task_ninja="$(command -v ninja)"
test -x "$task_ninja"
[[ ! -e "$task_work" && ! -L "$task_work" ]] || fail 'current output already exists'
[[ ! -e "$task_artifact" && ! -L "$task_artifact" ]] || fail 'artifact already exists'
# Validate all reusable source state before any reverse application or sync.
task_recorded=false
task_same_patches=false
if [[ -e "$task_depot" || -L "$task_depot" ]]; then
  check_checkout "$task_depot" "$task_depot_revision"
  git -C "$task_depot" diff --quiet || fail 'modified depot_tools'
  [[ "$(git -C "$task_depot" remote get-url origin)" = https://chromium.googlesource.com/chromium/tools/depot_tools.git ]] || fail 'unexpected depot_tools origin'
fi
if [[ -e "$task_source" || -L "$task_source" ]]; then
  check_checkout "$task_source" "$task_revision"
  [[ "$(git -C "$task_source" remote get-url origin)" = https://chromium.googlesource.com/v8/v8.git ]] || fail 'unexpected V8 origin'
fi
if [[ -e "$task_state" || -L "$task_state" || -e "$task_patch_state" || -L "$task_patch_state" ]]; then
  [[ -s "$task_state" && ! -L "$task_state" && -d "$task_patch_state" && ! -L "$task_patch_state" ]] || fail 'incomplete patch state; explicit recovery required'
  cmp -s "$task_state" <(source_diff) || fail 'source differs from recorded patches; explicit recovery required'
  task_recorded=true
  task_same_patches=true
  for task_patch in "${task_patches[@]}"; do
    [[ -f "$task_patch_state/$task_patch" && ! -L "$task_patch_state/$task_patch" ]] || fail 'incomplete patch copies'
    cmp -s "$task_repo/patches/$task_patch" "$task_patch_state/$task_patch" || task_same_patches=false
  done
elif [[ -d "$task_source/.git" ]]; then
  git -C "$task_source" diff --quiet || fail 'unrecorded source changes; explicit recovery required'
fi
if [[ -e "$task_build/.gclient" || -L "$task_build/.gclient" ]]; then
  [[ -f "$task_build/.gclient" && ! -L "$task_build/.gclient" ]] || fail 'invalid gclient config'
  cmp -s "$task_build/.gclient" <(gclient_config) || fail 'unexpected gclient config'
fi
# This cache is tied to one GN/Rust dependency closure. Keeping stale rlibs is
# safe only while that graph stays fixed; never silently repurpose an old out.
if $task_cached && [[ -e "$task_out" || -L "$task_out" ]]; then
  [[ -d "$task_out" && ! -L "$task_out" ]] || fail 'invalid cached output directory'
  if [[ -n "$(find "$task_out" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    $task_recorded || fail 'cached output has no known patch state'
    [[ -f "$task_out/args.gn" && ! -L "$task_out/args.gn" ]] || fail 'cached output has no regular args.gn'
    cmp -s "$task_repo/args.linux.x64.gn" "$task_out/args.gn" || fail 'GN configuration changed; use a new cache directory'
    check_cpp_patch "$task_state"
    for task_patch in "${task_patches[@]}"; do
      check_cpp_patch "$task_repo/patches/$task_patch"
    done
  fi
fi
mkdir -p "$task_build" "$task_info" "$(dirname "$task_artifact")"
df -h "$task_build" "$task_work"
if [[ ! -d "$task_depot/.git" ]]; then
  git init "$task_depot"
  git -C "$task_depot" remote add origin https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
if ! git -C "$task_depot" rev-parse --verify HEAD >/dev/null 2>&1; then
  git -C "$task_depot" fetch --depth=1 origin "$task_depot_revision"
  git -C "$task_depot" checkout --detach FETCH_HEAD
fi
test "$(git -C "$task_depot" rev-parse HEAD)" = "$task_depot_revision"
export PATH="$task_depot:$PATH"
export DEPOT_TOOLS_UPDATE=0
export DEPOT_TOOLS_METRICS=0
if [[ ! -e "$task_build/.gclient" ]]; then gclient_config > "$task_build/.gclient"; fi
if [[ -f "$task_source/DEPS" ]]; then check_dependencies allow-missing; fi
if $task_recorded && ! $task_same_patches; then
  git -C "$task_source" apply --reverse --check "$task_state"
  git -C "$task_source" apply --reverse "$task_state"
  git -C "$task_source" diff --quiet
fi
# Always let gclient check its complete package graph. Its existing downloads
# are reused; no --force/--reset/--delete_unversioned_trees is permitted here.
(
  cd "$task_build"
  gclient sync --no-history --jobs 2 --revision "v8@$task_revision"
)
check_checkout "$task_source" "$task_revision"
check_dependencies required
if $task_recorded && $task_same_patches; then
  cmp -s "$task_state" <(source_diff) || fail 'sync changed recorded V8 source'
  printf '%s\n' 'Reusing unchanged V8 patches and Ninja output; all native gates will run'
else
  git -C "$task_source" diff --quiet
  for task_patch in "${task_patches[@]}"; do
    git -C "$task_source" apply --check "$task_repo/patches/$task_patch"
    git -C "$task_source" apply "$task_repo/patches/$task_patch"
  done
  if $task_cached; then
    mkdir -p "$task_patch_state"
    for task_patch in "${task_patches[@]}"; do
      cp "$task_repo/patches/$task_patch" "$task_patch_state/$task_patch"
    done
    source_diff > "$task_state"
    test -s "$task_state"
  fi
fi
test "$(git -C "$task_source" rev-parse HEAD)" = "$task_revision"
git -C "$task_source" diff --cached --exit-code
python3 - "$task_source/include/v8-version.h" "$task_version" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
names = ['MAJOR_VERSION', 'MINOR_VERSION', 'BUILD_NUMBER', 'PATCH_LEVEL']
version = '.'.join(re.search(r'^#define V8_' + name + r'\s+(\d+)', source, re.M).group(1) for name in names)
if version != sys.argv[2]:
    raise SystemExit('V8 source version mismatch: ' + version)
PY
git -C "$task_source" diff --check
mkdir -p "$task_out"
if ! cmp -s "$task_repo/args.linux.x64.gn" "$task_out/args.gn"; then
  cp "$task_repo/args.linux.x64.gn" "$task_out/args.gn"
fi
cmp "$task_repo/args.linux.x64.gn" "$task_out/args.gn"
cp "$task_out/args.gn" "$task_info/args.gn"
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
(
  set -o noclobber
  tar -C "$task_seed" -czf - v8 > "$task_artifact"
)
test -s "$task_artifact"
df -h "$task_work"
