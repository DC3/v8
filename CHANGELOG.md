# 变更记录

## [2026-10-14] 修正相同补丁缓存的 gclient 同步模式

- Forgejo105 在依赖同步阶段因强制指定 V8 revision 而拒绝已有补丁的工作区，尚未进入 native 构建。仅对已核验且四份补丁逐字相同的缓存省略 revision 覆盖，沿既有 managed=False 保持 V8 根 HEAD；初建或补丁变化恢复干净源码后仍显式固定 revision。
- 使用参数数组保留完整 Git/CIPD/GCS 依赖与 hooks 同步、同步前后源码检查、原构建目标和全部 30 项 native 门禁；不使用 force/reset 或跳过依赖。静态检查后交独审，真实缓存构建结果待主控验收。

## [2026-10-14] 修正 bounded native 永久回归的 V8 15.3 接线

- Forgejo104 已越过 optimizer visitor 链接缺口，后在 test-api 的 Context::GetIsolate 编译失败；改为同版 LocalContext 默认使用的 CcTest::isolate，保留局部 HandleScope 和全部原生断言。
- 单行差异已重新独审，昨日候选关键边界另行复核；缓存、完整构建目标、30项 native 与原消费门禁保持，修复后真实结果待验收。

## [2026-10-13] 为本地 full seed 构建增加可选持久缓存

- 支持显式绝对路径 LOBUN_V8_BUILD_CACHE，复用固定 revision 的 depot_tools、V8 源码、gclient 依赖、Clang/Rust 和 Ninja 输出；未设置时保留 GitHub 原有 scratch 构建。seed、build-info 和最终包仍由本次独立输出生成。
- 缓存入口拒绝路径重叠、未知 revision、暂存修改、新未跟踪源码及实际 diff 与记录不符。用 gclient 原生 DEPS 映射核对每个 Git 子仓的 HEAD、origin 与工作区；每轮仍受控 sync 完整包依赖和 hooks，复用已有下载。仅保存当前可逆 .applied.patch 和四份补丁原文；相同补丁不反向或重应用，补丁变化时先核对再恢复，不执行 reset。
- 既有 Ninja 输出限定同一 GN 参数及固定依赖闭包，仅允许 C++ .cc/.h 补丁；配置或构建图变化要求新缓存目录，保留旧目录，防止打包混入旧 Rust archive。相同参数不重写；每次执行 GN、三个 Ninja 目标和全部 30 项 native 门禁，不缓存 PASS。中断的不一致状态拒绝自动恢复；仅静态检查，真实缓存复用与 native 全链路验收待主控执行。
- 首轮 GitHub 与本地 CI 均因缺少 MaglevGraphOptimizer::VisitCallBoundedNative 定义而在 mksnapshot 链接失败；另行补齐 8 行 visitor，保留调用及内存副作用，已通过非作者源码审查，修复后的真实 CI 仍待复跑验收。

## [2026-10-13] 实施受限 bounded native leaf 的 Maglev 候选

- 新增逐 callee 不可变、默认关闭的 NativeCallContract；仅显式承诺有界、不阻塞、不触 VM/GC/JS 重入的静态 native void()/i32(i32) 可进入新路径，不修改同签名共享 builder 实例。
- Linux x64 普通 Maglev 复用既有 math C-call，保真实 receiver、调用前严格转换、保守内存 effects、Smi32 与调用后恢复；TF、Turbolev、未标记函数及其他调用形状保持原路径。生产源码独立审查通过，尚未完整构建或证明收益。
- 原 27 项 native 门禁后追加三项永久回归，检查实际 Maglev 命中、同签名隔离、GC、溢出/lazy deopt exactly-once 与并发终止恢复；完整 seed 成套携带新 headers/lib，消费者必须重编 wrappers/napi。

## [2026-10-13] 允许受限调整 full seed 的 Ninja 并发

- 构建脚本支持 LOBUN_V8_BUILD_JOBS，默认 2，仅接受 1 至 16 的整数；在创建目录或获取源码前拒绝非法输入，本地可显式使用 8。
- 两次 Ninja 调用与 build-info 共用实际并发值；gclient 并发 2、270 分钟预算、完整构建目标及 27 项原生门禁保持。

## [2026-10-13] 适配命名空间补丁的 V8 15.3 内部 API

- CI38352726699 实际编译至 1482/3056 后，命名空间 marker getter 因旧 IsTrue(obj, isolate) 重载失败；改用 15.3 原有的一参谓词，并同步修正命名空间原型的 IsNull 调用。
- 私有 marker 初始化沿同函数已有导出属性初始化合同，检查 SetNormalizedProperty 的 Maybe<bool> 返回值；保留命名空间语义、构建配置、三份补丁顺序与 27 项原生门禁，实际构建和验收由后续 CI 执行。
- 同一个 270 分钟构建预算内先编译两个命名空间对象，再完成原三个目标；Ninja 复用同一输出，尽早报告此类移植错误，不重复编译或减少门禁。

## [2026-10-13] 关闭 V8 未使用的 GLib 构建依赖

- 第二轮 CI38351688567 通过 Ninja 检查，在 GN 全局配置求值时因 runner 缺少 GLib 开发包失败，尚未编译 V8；保留原失败日志。
- 显式设置 use_glib=false：固定源码的 V8 目标和 lo 事件循环均未使用 GLib，消除 Chromium Linux 配置默认触发的 pkg-config 检查；保留 use_sysroot=false、标准库、引擎能力与原生门禁配置。

## [2026-10-13] 修正手动构建的 Ninja 选择

- 首轮 CI38351053324 在 Ninja 版本检查失败：depot_tools 的未 bootstrap 包装脚本遮住 runner 工具，尚未进入 GN/V8 编译；保留原失败记录。
- 调整 PATH 前固定 runner 原 Ninja 路径，构建与版本检查使用同一工具；V8/Clang/Rust、补丁、能力配置与27项门禁保持。

## [2026-10-13] 固定 V8 15.3 Linux x64 full seed 手动构建

- 手动 workflow 固定 V8 15.3.76.24 源码与 depot_tools revision，在 Ubuntu 24.04 使用 bundled Clang/Rust；三份补丁按明确顺序应用。
- 原 26 项 context、Fast API/profiler、termination native gates 不减少，另加一项 receiverless 长期回归；缺失或零测试不算通过。
- 使用两个 ninja jobs 和明确超时，无 V8 cache、sudo 或依赖安装脚本；单个 workflow artifact 成套保留 patched headers/source、gen、monolith、所有 Rust rlibs/rsp 和实际构建配置。
- 消费者须用新 headers 重编 V8 wrapper/napi_impl；保持 release workflow 不变，不发布 tag/release。本地仅静态检查，真实 CI 与 runtime 消费验收由主控推进。
