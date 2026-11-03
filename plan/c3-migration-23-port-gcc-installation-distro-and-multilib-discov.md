---
title: 'C3 migration 23 [Driver & toolchains]: port GCC installation, distro and multilib discovery'
state: waiting
depends_on:
- c3-migration-07-replace-zig-target-metadata-with-explicit-c3-tar
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
sessions:
- 01a1a1dc-3141-7cb2-a221-cf59333347e4
---

Add src/c3/toolchain/{gcc_version,gcc_detector,distro,multilib}.c3 and test/c3/toolchain_discovery_tests.c3. Translate Toolchain/GCCVersion.zig parse/isLessThan (including unusual preference for missing minor/patch/suffix), GCCDetector.zig prefixes/triple aliases/library scanning/selection, Distro.zig release-file recognition and Multilib.zig flags/suffixes/selection. Introduce a small filesystem/environment discovery interface based on Toolchain.zig exists/readFile/joinedExists so these algorithms run on synthetic directory trees without a complete Driver. Preserve target-versus-host distinctions, sysroot paths, explicit GCC prefix precedence and TooManyMultilibs failure. Keep current supported architectures and fallback behavior; do not add new distro support as part of translation.
Run bazel test //test/c3:toolchain_discovery_tests. Port existing embedded version/selection tests, add competing versions, missing installations, alternate triples, 32/64-bit siblings, malformed release files and sysroot isolation. Compare selected installation, multilib and derived paths to pinned Zig probe results for identical directory trees. No test should discover the developer's real /usr or /opt implicitly

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
