---
title: 'C3 migration 33 [Public library & release]: switch documented defaults after final parity and packaging gates'
state: waiting
depends_on:
- c3-migration-32-make-bazel-builds-portable-and-enforce-migration
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Update README.md, test/README.MD and docs/c3-migration.md/docs/c3-api.md to make C3+c3c+Bazel the primary supported build/library workflow only after all migration gates pass. Add a concise numbered migration index with ticket milestones/dependencies, exact commands for unit/frontend/record/CLI/consumer/fuzz suites, compiler provisioning and how to reproduce the frozen Zig comparison. Correct test/README.MD's expand_partial explanation to match the runner's suffix-file behavior, and document current compare_output skips without implying executable codegen coverage. Keep experimental backend limitations prominent.
Finalize //:aro and //:aro_c3 defaults and //:aro_distribution; leave a clearly labeled legacy/reference Zig build available for comparison rather than deleting it or silently breaking existing consumers. Audit production build/run dependency closure for Zig or sibling-project paths. Existing Builtins/update.patch/README.md describe a Zig-based external Clang table-maintenance tool; explicitly label it optional legacy maintenance, outside the C3 production build, and document the C3 .def-to-source generator as the normal build step. Retain MIT and Unicode notices and unchanged C resource headers.
Run clean debug/optimized production builds, bazel test //..., explicit differential frontend/record/backend suites, relocated public-consumer package test and deterministic fuzz replay using the pinned CI matrix. Reconcile all baseline inventories and expected failures; no new unexplained skips or blanket golden updates. Capture runtime/peak-memory measurements on fixed representative translation units alongside the reference to make regressions visible, without inventing an arbitrary performance threshold. Publish the gate results and tested version/support matrix in the migration document. If any required parity/platform gate fails, retain old documented defaults and report the exact blocker; do not call the migration complete.


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Confirm 01–32 are complete and list which gates to run.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **33.1 `docs`**: owns README.md, test/README.MD, docs/*. Primary workflow, numbered migration index, exact commands, expand_partial fix, compare_output note.
- **33.2 `defaults`**: owns BUILD.bazel defaults, legacy Zig labeling. Finalize //:aro, //:aro_c3, //:aro_distribution; label legacy Builtins tooling.
- **33.3 `closure-audit`**: owns dependency audit. No Zig or sibling-project paths in production closure; notices retained.
- **33.4 `gates`**: owns CI matrix runs (one agent per suite). unit/frontend/record/backend/consumer/fuzz replay on each host.
- **33.5 `perf`**: owns measurement report. Runtime/peak memory vs reference on fixed translation units.

**Stage 2: integrator (1 agent, serial).** Publish the gate results in docs/c3-migration.md. Switch the defaults only if every gate passes; otherwise report the exact blocker.
