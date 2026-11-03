# Brief for every migration agent

You are porting the Aro C compiler (Zig, in this repo) to C3.

1. Start with `git merge --ff-only claude/gifted-feynman-kwly55`. Your worktree may have been created from an older commit.
2. Read `plan/PARALLEL.md` (environment, tools, rules) and `src/c3/CONVENTIONS.md` (mandatory coding conventions and c3c 0.8.5 quirks). Then read your plan file and the Zig sources it names.
3. No Zig binary exists, so the Zig source is the reference. Expected values come from `test/cases`, `test/records`, embedded Zig `test` blocks, or careful reading of the Zig code. Mark any hand-derived value as source-derived. Never claim parity with an executable that was not run.
4. Build and test with:
   `C3C=/home/user/tools/c3/c3c /home/user/tools/bazel --output_user_root=/home/user/tools/bazel_root test //test/...`
   Also run it with `-c opt`.
5. Edit only the files you were given. You may add your own lines to `BUILD.bazel` / `test/c3/BUILD.bazel` lists and add new targets. Keep each addition as its own line or block, so merges are mechanical.
6. If you need an API change in a file you don't own, use a local workaround or stub, and list the change in your report.
7. Add any new c3c quirk you hit to `CONVENTIONS.md`, one line each.
8. Commit on your worktree branch, and do not push. Commit messages end with:

       Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
       Claude-Session: https://claude.ai/code/session_016FBAJoYxgfUzsPZupT5cxe

9. Final report, kept concise: branch, commits, files, real test results, deviations, unverifiable items, API changes needed from others, c3c issues.
