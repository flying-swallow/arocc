---
title: 'C3 migration 30 [Public library & release]: publish the embeddable C3 library and resource bundle'
state: waiting
depends_on:
- c3-migration-29-connect-backend-modes-and-external-tool-executio
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Complete src/c3/aro.c3 public exports corresponding to src/aro.zig and src/backend.zig, including Compilation/Source/Tokenizer/Preprocessor/Parser/Tree/TypeStore/Value/Diagnostics, Driver/Toolchain and existing backend APIs. Add a public Bazel library target //:aro and a package target //:aro_distribution, extending tools/c3.bzl/project.json only where reusable library dependency support is needed. Include existing include/*.h unchanged as declared resources and document resource-directory selection independent of CWD. Package C3 modules/library artifact as appropriate for the pinned c3c version, resource headers, version metadata and existing license notices. Document API ownership, allocator/error handling, source/tree lifetime and the old Zig-to-new-C3 API mapping in new docs/c3-api.md. Zig source-level compatibility is not implied by changing languages; leave the original Zig module/reference available during migration.
Add examples/parse_buffer.c3 and an isolated test/migration/consumer workspace with its own MODULE.bazel/project.json/BUILD.bazel. The consumer must import only the public dependency, parse a buffer/include, inspect AST/types/diagnostics, recover from a malformed unit, and release allocations. Run bazel test //test/migration:library_consumer and build //:aro_distribution. Test extraction/relocation away from the repository and build/run with Zig absent from PATH. Audit runtime/build dependencies to ensure no Zig executable or sibling template checkout is needed. Do not create a broad C ABI redesign; only the existing fuzz C entrypoint is required by its separate ticket

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
