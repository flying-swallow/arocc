// #kind: expand_error
// #opt: -std=c23
#ifdef FOO
#error invalid
#elifdef
#error invalid // #error@9: macro name missing
#else
int
#endif

#define BAR
#ifdef FOO
#error invalid
#elifndef
#error invalid // #error@10: macro name missing
#else
int
#endif

