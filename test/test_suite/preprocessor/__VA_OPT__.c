// #kind: expand_error
#define foo(...) __VA_OPT__(1, 2, ) __VA_OPT__(3, 4)
foo(1)

#define bar(...)  a ## __VA_OPT__(3, 4) +
bar()

#define baz() __VA_OPT__(1)
baz()

#define invalid1(...) __VA_OPT__ 1 // #error@33: missing '(' following __VA_OPT__
#define invalid2(...) __VA_OPT__(1 // #note@33: to match this '('
 // #error@35: unterminated __VA_OPT__ argument list
