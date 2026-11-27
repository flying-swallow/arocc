// #opt: -fmacro-backtrace-limit=1
// #note: (skipping 1 expansions in backtrace; use -fmacro-backtrace-limit=0 to see all)
#define FOO(X) X
FOO(2) // #error@1: expected external declaration // #note@5: expanded from here

