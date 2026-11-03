# Running the C3 migration plans with parallel agents

Each waiting plan (08–33) ends with a **Parallel agent breakdown** section. Plans 01–07 are `state: complete` and have no breakdown.

## Shape of every breakdown

1. **Stage 0: contract (1 agent).** Lands the shared types, handle and record layouts, and function signatures. Bodies are stubs that return an explicit `unsupported` fault. Merge this before stage 1 starts so every parallel agent compiles against the same API.
2. **Stage 1: parallel agents.** Each agent works in its own git worktree (`isolation: "worktree"`) and owns a disjoint set of files. If an agent needs an API change in another agent's file, it reports the change to the integrator instead of making the edit itself. An agent can be done against stubs, as long as its own unit checks pass.
3. **Stage 2: integrator (1 agent).** Merges the stage 1 branches, writes or registers the `//test/c3:*` / `//test/migration:*` targets, runs dbg+opt and the plan's acceptance commands, and fixes seams between the agents' work.

## Environment and tools

- `c3c` 0.8.5 (release build) is at `/home/user/tools/c3/c3c`. The pinned 0.8.6 pre-release from plan 02 needs LLVM 19+ to build, and the container has LLVM 18.
- Bazel 9.1.0 is at `/home/user/tools/bazel`. `.bazelrc` points the registry at the GitHub-hosted copy of the BCR, because `bcr.bazel.build` is blocked.
- Run Bazel as: `C3C=/home/user/tools/c3/c3c /home/user/tools/bazel --output_user_root=/home/user/tools/bazel_root test //test/c3:<target>` (add `-c opt` for opt).
- **No Zig executable.** The required Zig 0.18.0-dev can't be downloaded here. The Zig sources under `src/` are the reference: read them and port the behavior. Expected values come from the existing fixtures (`test/cases`, `test/records`, embedded Zig `test` blocks) or from careful reading of the Zig code. Any step a plan describes as "generate from the pinned Zig executable" becomes "derive by hand from the Zig source, and mark the vector as source-derived". Never claim differential parity against a binary that was not run.
- Bazel `c3_library`/`c3_test`/`c3_binary` rules live in `tools/c3.bzl`. Sources are listed explicitly in `BUILD.bazel` files, which replaces the `project.json` lists the plans mention.

## Rules shared by all agents

- **Only the integrator edits the shared `BUILD.bazel` files.** Parallel agents may add a private test target while they work, but must list every source and test file in their final report so the integrator can register them as explicit paths.
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
