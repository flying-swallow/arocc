// #kind: expand_error
// #opt: --emulate=gcc
/** manifest:
expand_error
args = --emulate=gcc

unterminated macro function at eof gcc.c:9:1: error: unterminated function macro argument list
*/

#define foo(X) X
foo(1, // #error@1: unterminated function macro argument list
