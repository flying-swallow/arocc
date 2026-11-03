---
title: 'C3 migration 01 [Build & validation]: Freeze the Zig reference and regression inventory'
state: waiting
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
sessions:
- 01a19f89-c32f-7b42-a5f2-5c1622d8050d
---

Establish the reference before porting behavior. Read build.zig, build.zig.zon, src/aro.zig, test/runner.zig, test/record_runner.zig and test/README.MD. build.zig.zon requires Zig 0.18.0-dev.828+9da287565; planning environment has 0.17.0-dev.1818+7051f8e73, so do not treat that compiler's failures as Aro regressions. Add docs/c3-migration.md and a machine-readable test/migration/baseline.json with the source commit, exact usable Zig revision, tool versions, commands, test counts and existing failures/skips. Use a compatible pinned Zig without modifying the implementation to suit the older compiler. Run zig build, zig build test-unit, zig build test-integration and zig build test-record; capture actual outcomes, including record runner prerequisites. Inventory every top-level test/cases/*.c manifest and the embedded Zig unit tests; distinguish unimplemented compare_output from active cases. Record the public exports in src/aro.zig and current experimental backend limitations as parity requirements, not promises to implement missing codegen. Preserve original sources and fixtures throughout the port. Document how to rebuild the Zig reference in a separate output/cache directory and retain an executable for differential checks. Acceptance: repeatable reference invocation, complete fixture count, explicit baseline failures with reasons, and no claim of a green suite without logs. If a compatible Zig cannot be obtained, report this blocker rather than generating invented expected results.
