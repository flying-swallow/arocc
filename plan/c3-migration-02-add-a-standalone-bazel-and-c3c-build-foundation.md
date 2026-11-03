---
title: 'C3 migration 02 [Build & validation]: Add a standalone Bazel and c3c build foundation'
state: complete
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
sessions:
- 01a19f89-c330-76c2-9488-02f2b73db85a
---

Add MODULE.bazel, BUILD.bazel, tools/BUILD.bazel, tools/c3.bzl, tools/c3c_repo.bzl, project.json, a minimal src/c3/aro.c3 module and test/c3/build_smoke.c3. Template files already inspected: /home/michaelpollind/projects/buildy-crafty-game/{MODULE.bazel,project.json,tools/c3.bzl,tools/BUILD.bazel} and vendor/rhi-c3/tools/c3c_repo.bzl there. Reuse the template's staged project build, generated-source overlay, compilation-mode mapping and @test invocation patterns, but remove all RHI, SDL, shader, Cubyz version and native game dependencies; do not depend on that checkout or run vendor-fetch. Provide explicit source sets and project targets for library modules, test executables and eventual CLI; expose reusable source/library consumption rather than only an application wrapper. Discover C3C via environment/PATH with an actionable missing-tool error and validate/document the exact supported compiler (observed 0.8.6 pre-release, git 61d33ae1dce61f80dd81660db2f9910208c74284; Bazel 9.1.0). Treat the template's absolute host compiler and local test execution as local-only initially, not hermetic. Stage compiler inputs/data correctly, quote paths, propagate test failures and resolve runfiles outside the workspace CWD. Keep Zig builds intact. Acceptance: bazel build //:aro_c3 and bazel test //test/c3:build_smoke in dbg and opt configurations, including an intentional failing assertion checked during development; a clean checkout builds without the game tree. Add test/c3/BUILD.bazel and minimal documentation of these newly introduced target names.
