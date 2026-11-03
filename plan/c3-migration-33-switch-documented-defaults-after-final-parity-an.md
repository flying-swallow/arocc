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
