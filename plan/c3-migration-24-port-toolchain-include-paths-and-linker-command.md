---
title: 'C3 migration 24 [Driver & toolchains]: port toolchain include paths and linker command construction'
state: waiting
depends_on:
- c3-migration-23-port-gcc-installation-distro-and-multilib-discov
- c3-migration-15-port-includes-embed-pragma-lifecycle-and-depende
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/toolchain.c3 and toolchain/{linux,darwin}.c3, plus generated system_defaults.c3 settings in Bazel. Follow Toolchain.zig Options/discover/getProgramPath/getLinkerPath/defineSystemIncludes/addBuiltinIncludeDir/buildLinkerArgs/addRuntimeLibs; port Linux.zig path/linker policy and Darwin.zig SDK selection/xcrun handling. Preserve sysroot/resource-dir/nostdinc family, PATH/compiler/library environment, runtime and unwind choices, PIE/static/shared flags, startup files and linker selection/defaults from build.zig. Adapt the discovery filesystem abstraction to production filesystem access and injectable process execution. Keep unknown-target behavior explicit. Resource headers must resolve through Bazel runfiles and later installed layout, not the source checkout's absolute path.
Add test/c3/toolchain_tests.c3 with synthetic sysroots and fake linker/assembler/xcrun processes. Run bazel test //test/c3:toolchain_tests, checking ordered include/search/link argv against Zig, SDK stdout/stderr/status validation, missing executables, paths with spaces, no-default-libs and cross-target cases on any host. No real linker is needed for argument-construction acceptance. Platform-native smoke checks belong to CI; this ticket provides the behavior and portable unit fixtures

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
