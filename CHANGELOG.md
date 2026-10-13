# 变更记录

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
