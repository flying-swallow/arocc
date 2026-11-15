// #kind: expand_error
// #opt: --emulate=gcc
#define str(s) # s
#define xstr(s) str(s)
#define INCFILE(n) str(strcmp( // #note@20: expanded from here // #note@20: expanded from here
xstr(INCFILE(2)) INCFILE(2)) // #error@6: unterminated function macro argument list // #error@18: unterminated function macro argument list

