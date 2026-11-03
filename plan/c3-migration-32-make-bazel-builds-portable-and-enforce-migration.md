---
title: 'C3 migration 32 [Build & validation]: make Bazel builds portable and enforce migration CI'
state: waiting
depends_on:
- c3-migration-30-publish-the-embeddable-c3-library-and-resource-b
- c3-migration-31-restore-fuzzing-and-optional-profiling-with-baze
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Update .github/workflows/ci.yml and the new tools/c3.bzl, tools/c3c_repo.bzl, MODULE.bazel, project.json and Bazel test targets. The template's local compiler path and Bash-based local/no-sandbox tests are a starting point, not a portable toolchain. Pin a tested c3c revision/distribution and Bazel version; support explicit local compiler overrides and a documented reproducible CI provisioning path with checksum verification. Replace shell-specific launcher/runfiles assumptions where needed for Linux/macOS/Windows, including executable suffixes, path quoting, child processes and library linkage. Declare all sources/generated builtin files/resources; prove source and compiler changes invalidate actions. Do not mark local environment-dependent actions as remotely cacheable/hermetic.
Extend CI path filters to C3, Starlark, MODULE/project files, fixtures, headers and workflow changes. Preserve existing Zig reference checks in a separately pinned job during migration. Run C3 debug/optimized builds and full unit/frontend/record/CLI/consumer/corpus suites across the existing three-host matrix. Keep cross-target frontend/ABI tests distinct from cross-compiling the C3 executable; retain a 32-bit compilation check equivalent in purpose to the old arm-linux job where c3c supports it. Any unavailable platform/compiler artifact is a blocking, explicitly reported matrix gap, not a silently removed job.
Add a small CI smoke target early once the foundation exists if implementing this ticket incrementally, but completion requires the full matrix. Validate from clean checkouts, paths with spaces, no sibling project and no Zig on the production-build PATH. Record tested versions, platform results and remaining optional AFL/Tracy requirements in docs/c3-migration.md. Run bazel test //... for default tests; expensive reference/optional tool tests may be named explicit suites but must be run by appropriate CI jobs

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Pin the c3c revision/distribution and Bazel version; record checksums.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **32.1 `provisioning`**: owns `tools/c3c_repo.bzl`, MODULE.bazel. Checksummed download, local override, documented provisioning.
- **32.2 `portability`**: owns `tools/c3.bzl` launchers/runfiles. Windows/macOS suffixes, quoting, child processes, library linkage; drop Bash assumptions.
- **32.3 `ci`**: owns `.github/workflows/ci.yml`. Path filters, three-host matrix, separate pinned Zig reference job, 32-bit check.
- **32.4 `hermeticity`**: owns input declarations audit. Prove that source/compiler changes invalidate actions; no false remote-cacheable flags.
- **32.5 `validation`**: owns clean-checkout runs. Paths with spaces, no sibling project, no Zig on PATH; record results in docs/c3-migration.md.

**Stage 2: integrator (1 agent, serial).** Run `bazel test //...` and the named explicit suites in CI. Report any matrix gap as a blocker.
