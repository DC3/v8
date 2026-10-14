# V8 Linux x64 full seed

本 fork 的手动 workflow 为 lo-bun 构建固定的 **V8 15.3.76.24 Linux x64 full seed**。它提供成套引擎输入，不代表 lo-bun runtime 或产品性能已经准入。

## 固定输入

- V8：`107d9154d9d944f722c9f6af126849217660709c`，源码版本必须是 `15.3.76.24`。
- depot_tools：`2fd34a8813b6f34336aad40976cc4223768177f8`，禁用自动更新。
- 顺序应用 `patches/bun-module-namespace.patch`、`patches/guarded-osr-context.patch`、`patches/15.3-cfunctioninfo-has-receiver-kno.patch`、`patches/15.3-maglev-bounded-native-leaf.patch`。
- `.gclient` 显式 `checkout_rust=True`，使用该 revision 的 DEPS 下载 bundled Clang/Rust；不使用宿主编译器替换它们。
- [args.linux.x64.gn](args.linux.x64.gn)：Intl/Temporal/Rust 开启，pointer compression/sandbox 关闭；保留 cppgc、Wasm、TurboFan、Maglev 默认能力，不套用关闭 cppgc 的精简配方。

## 手动 CI

入口为 [.github/workflows/push.yml](.github/workflows/push.yml)，只响应 `workflow_dispatch`。选择含这些源码/补丁的分支，或由主控使用 `gh workflow run push.yml --ref <branch>`。文件名沿现有手动入口，push 本身不会启动构建。

单个 Ubuntu 24.04 x64 job 执行 [scripts/build-linux-x64-full.sh](scripts/build-linux-x64-full.sh)，构建 `v8_monolith cctest v8_unittests`。ninja 默认两个 jobs，可显式设置 `LOBUN_V8_BUILD_JOBS`（本地为8）；整个 job 上限360分钟，每个 native case 上限300秒。手动 workflow 的并发组跨分支串行、不取消正在构建的任务。脚本不安装系统依赖，不调用 sudo 或 install-build-deps.sh。

本地可显式设置 `LOBUN_V8_BUILD_CACHE`，复用固定源码、完整依赖下载与同配置 Ninja 输出；未知源码、依赖或 GN/Rust 图变化拒绝复用。每轮仍同步完整依赖/hooks、构建全部目标、执行全部 native gates，再生成独立 seed 与 artifact，历史 PASS 不缓存。GitHub 使用 scratch 构建作为兜底。

现有 `.github/workflows/main.yml` release 流程保持原样。本入口不创建 tag/release，也不发布 release asset；主控仍需避免与独立 release/native 构建重叠。

## 长期 native gates

原26项逐项保留：context14、Fast API/profiler9、termination3；另加 `test-api/FastApiCallsWithoutReceiver`，合计27项。bounded 另有3项 Maglev 与2项 TurboFan 回归，再加2项永久OSR语义回归，总34项；全部通过才打包。

- context：两个 guarded OSR case、Load/Store NoCell各四项、四个 SpecializeJSFunction case。
- Fast API：原8个 test-api case 与 FastApiCPUProfiler；新增 receiverless case 覆盖 void()/i32(i32)、实际 fast 计数和 slow/string fallback。
- termination：原三个 ThreadTerminationTest filter。
- OSR语义：FastApiBoundedNativeEarlyOsrPeeling 与 FastApiBoundedNativeEarlyOsrPeelingTermination，覆盖当前TF帧、剩余零/一/多轮、错误与溢出、call后GC/lazydeopt次数、嵌套fallback和终止取消恢复。跨i32边界不等于已证明eager deopt；保留case名不表示生产启用early OSR peeling。

脚本先检查 cctest 的实际列表，逐项按完整 selector 运行；termination 每项必须报告一个通过的测试。缺 case、零测试、native失败或超时都会阻断打包与上传。准确 selector 和命令直接保留在同一长期构建脚本，不维护第二份 runner。

这些 native gates 不替代 lo-bun correctness、原 HTTP/FFI/file 门禁或 runtime 消费验收。新增 kNo 测试不表示正式 runtime 已切换 receiverless 接线；首轮消费者仍保留原 kYes wiring。

kNo 官方补丁的本次实验范围是普通 JS→TurboFan 单签名；accessor、Wasm、混合 overload 未完整支持，Maglev 仍走 slow，不能据新增 cctest 宣称通用支持。

bounded-no-vm 是独立的逐 callee 不可变合同，默认关闭，仅为源码已审的有界、不阻塞、不进入 VM/GC/JS/interrupt 的静态 void()/i32(i32) 叶函数提供受限 Linux x64 路径，仍保留真实 receiver 与严格输入。默认函数不因同签名进入该路径；这份合同不开放 native 内 GC、异常或 deopt，不等同无副作用。

## 单个成套产物

成功后上传唯一 workflow artifact：`v8-linux-x64-15.3.76.24-full`，其中为同名 `.tar.gz`。解包后沿现有 seed 布局：

```text
v8/
  include/                 同一 patched source 的公开 headers
  src/                     同一 patched source
  gen/                     同次构建的 generated source
  libv8_monolith.a          同次构建的 monolith
  rust-rlibs/               obj/、local_rustc_sysroot/ 中所有 rlibs
  rust-rlibs.rsp            保留输出相对路径及现有 linker group 格式
  build-info/              实际 args、source/toolchain 与 native测试输出
```

Rust rsp 内的 `v8/rust-rlibs/...` 从消费者 seed 根目录解释。headers、gen、monolith 和 Rust closure 必须整套消费，不能选取单个压缩包与旧版本拼接。实际 GN args、effective args/defines、source/toolchain版本与全部native结果在 build-info；失败任务不会上传成可消费的成功 seed。

本产物只负责 V8 引擎部分。消费者必须用该套新 headers **重编所有 V8 wrapper 和 napi_impl**，不得直接复用依赖旧 V8 ABI 的 `.o`；无 V8 依赖的纯 C/C++第三方库可按原消费合同复用。full native source/closure 的组装、最终 runtime 链接及测试由 lo-bun producer 持有，不推给本 fork 的 CI。

## 验证边界

成套artifact以精确head的成功CI为准，原生门禁不代替真实runtime性能验收。其他平台、Debug、sandbox、pointer compression配置须独立验证。
