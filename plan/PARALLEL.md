# Running the C3 migration plans with parallel agents

Each waiting plan (08–33) ends with a **Parallel agent breakdown** section. Plans 01–07 are `state: complete` and have no breakdown.

## Shape of every breakdown

1. **Stage 0: contract (1 agent).** Lands the shared types, handle and record layouts, and function signatures. Bodies are stubs that return an explicit `unsupported` fault. Merge this before stage 1 starts so every parallel agent compiles against the same API.
2. **Stage 1: parallel agents.** Each agent works in its own git worktree (`isolation: "worktree"`) and owns a disjoint set of files. If an agent needs an API change in another agent's file, it reports the change to the integrator instead of making the edit itself. An agent can be done against stubs, as long as its own unit checks pass.
3. **Stage 2: integrator (1 agent).** Merges the stage 1 branches, writes or registers the `//test/c3:*` / `//test/migration:*` targets, runs dbg+opt and the plan's acceptance commands, and fixes seams between the agents' work.

## Rules shared by all agents

- **Only the integrator edits `project.json` and `BUILD.bazel` files.** Parallel agents list the sources and test files they need in their final report, and the integrator adds them as explicit paths (c3c does not expand `dir/*.c3`).
- Zig sources, fixtures and expected files are read-only.
- "Vectors" / "goldens" / "refs" agents produce test data from the pinned Zig reference (see plan 01 / `test/migration/baseline.json`). They never hand-write expected output. If the pinned Zig is unavailable, report that as a blocker.
- Nothing in production targets may depend on Zig.
- Every agent's final report includes: files changed, tests run (with real output), stubs it still relies on, and open questions for the integrator.

## Cross-plan waves (from `depends_on`)

Plans in the same wave are independent and can run at the same time, each with its own stage 0→1→2 pipeline.

| Wave | Plans |
|---|---|
| done | 01–07 |
| 1 | 08, 23 |
| 2 | 09, 12 |
| 3 | 10 |
| 4 | 11 |
| 5 | 13 |
| 6 | 14, 16 |
| 7 | 15, 17 |
| 8 | 18, 24 |
| 9 | 19 |
| 10 | 20 |
| 11 | 21 |
| 12 | 22 |
| 13 | 25, 26, 31 |
| 14 | 27, 28 |
| 15 | 29 |
| 16 | 30 |
| 17 | 32 |
| 18 | 33 |

Plan 23 depends only on 07, so it can run any time before 24. It is off the critical path. The critical path is 08→09→10→11→13→14/16→15/17→18→19→20→21→22→25→28→29→30→32→33. Most of the speedup therefore comes from parallelism *inside* each plan, not between plans.
