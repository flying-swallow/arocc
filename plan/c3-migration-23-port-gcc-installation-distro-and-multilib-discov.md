---
title: 'C3 migration 23 [Driver & toolchains]: port GCC installation, distro and multilib discovery'
state: complete
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

## Completion notes

- Landed `src/c3/toolchain/discovery.c3` (`aro::toolchain::discovery`). It provides the `FileSystem` vtable (exists/read_file/joined_exists/list_dir) and `Env`, which bundles the filesystem, target, sysroot and `gcc_install_prefix`. It also has a port of std.fs.path.join, the synthetic `MemTree` with an access log, and a `host_fs()` backend for the Driver. The other new files are `gcc_version.c3`, `gcc_detector.c3`, `distro.c3` and `multilib.c3`. All are listed in `//:aro_c3_lib`. `//test/c3:toolchain_discovery_tests` is registered in `test/c3/BUILD.bazel` (Bazel replaces project.json, see PARALLEL.md).
- The 27 tests use only `MemTree`, never `host_fs()` or the real /usr, /opt or /etc. They cover:
  - the ported Zig tests (GCCVersion `parse`, Distro scan*);
  - competing versions, missing installations, and alternate and cross triples;
  - 32/64-bit and x32 siblings, and the biarch lib dirs;
  - malformed and truncated release files;
  - explicit-prefix precedence and /opt/rh ordering;
  - sysroot isolation, checked against the access log.
- Stage 1 ran serially in the lead session, because no sub-agent launcher was available there.
- `test/migration/toolchain_probe.zig` was not added: there is no Zig executable here (PARALLEL.md). Every expected selection is source-derived from GCCDetector.zig for the same synthetic tree, and no differential parity is claimed.
- These Zig quirks are kept verbatim and documented in the source and tests:
  - With a sysroot, the second prefix is `"/usr" ++ sysroot`.
  - x86 has no triple aliases.
  - A redhat-release or debian_version file that exists but is not recognized stops distro detection with `unknown`.
  - An x32 target cannot use an `/x32` multilib, because the select flags ask for +m32.
  - TooManyMultilibs cannot happen through the biarch path, so it is tested on `Detected.select` directly.
- Deviations:
  - Detector strings are owned by `GccDetector` (freed by `free`) instead of `Compilation.arena`.
  - `version` borrows from an owned copy, whereas Zig's points into the dir iterator's buffer.
  - `host_fs` follows symlinks when it classifies entries; Zig's `entry.kind` does not. `MemTree.add_other` models a symlink for tests.
  - The Linux.zig path assembly (addMultiLibPaths etc.) is left for plan 24.
