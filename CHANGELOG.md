# 变更记录

## [2026-10-13] 修正手动构建的 Ninja 选择

- 首轮 CI38351053324 在 Ninja 版本检查失败：depot_tools 的未 bootstrap 包装脚本遮住 runner 工具，尚未进入 GN/V8 编译；保留原失败记录。
- 调整 PATH 前固定 runner 原 Ninja 路径，构建与版本检查使用同一工具；V8/Clang/Rust、补丁、能力配置与27项门禁保持。

## [2026-10-13] 固定 V8 15.3 Linux x64 full seed 手动构建

- 手动 workflow 固定 V8 15.3.76.24 源码与 depot_tools revision，在 Ubuntu 24.04 使用 bundled Clang/Rust；三份补丁按明确顺序应用。
- 原 26 项 context、Fast API/profiler、termination native gates 不减少，另加一项 receiverless 长期回归；缺失或零测试不算通过。
- 使用两个 ninja jobs 和明确超时，无 V8 cache、sudo 或依赖安装脚本；单个 workflow artifact 成套保留 patched headers/source、gen、monolith、所有 Rust rlibs/rsp 和实际构建配置。
- 消费者须用新 headers 重编 V8 wrapper/napi_impl；保持 release workflow 不变，不发布 tag/release。本地仅静态检查，真实 CI 与 runtime 消费验收由主控推进。
