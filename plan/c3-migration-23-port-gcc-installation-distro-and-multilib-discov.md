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


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Define the filesystem/environment discovery interface (exists/readFile/joinedExists/listDir) and a synthetic in-memory tree implementation.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **23.1 `gcc-version`**: owns `src/c3/toolchain/gcc_version.c3`. parse/isLessThan including missing minor/patch/suffix preference; port embedded tests.
- **23.2 `gcc-detector`**: owns `src/c3/toolchain/gcc_detector.c3`. Prefixes, triple aliases, library scanning, selection, sysroot, explicit prefix precedence.
- **23.3 `distro`**: owns `src/c3/toolchain/distro.c3`. Release-file recognition, malformed files.
- **23.4 `multilib`**: owns `src/c3/toolchain/multilib.c3`. Flags/suffixes/selection, TooManyMultilibs.
- **23.5 `probe`**: owns `test/migration/toolchain_probe.zig`, synthetic trees. Pinned-Zig results for identical directory trees.

**Stage 2: integrator (1 agent, serial).** Write `test/c3/toolchain_discovery_tests.c3`, register the target, and check nothing reads the real /usr or /opt.
