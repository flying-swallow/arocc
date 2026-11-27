#pragma GCC

#pragma GCC warning // #error@13: pragma warning requires string literal

#pragma GCC warning non_string // #error@13: pragma warning requires string literal

#pragma GCC warning "A warning" // #warning@13: A warning [-W#pragma-messages]

#pragma GCC warning ("Another" " warning") // #warning@13: Another warning [-W#pragma-messages]

#pragma GCC error // #error@13: pragma error requires string literal

#pragma GCC error non_string // #error@13: pragma error requires string literal

#pragma GCC error ("An error") // #error@13: An error

#pragma GCC error "Another" " error" // #error@13: Another error

#if 0
#pragma GCC error "Should not happen"
#endif

#define P(s) _Pragma(#s)

#define foo(x) P(message #x)
foo(bar 1) // #note@1: #pragma message: bar 1
foo(baz 2) // #note@1: #pragma message: baz 2

#warning foo \ // #warning@2: foo bar [-W#warnings]
bar

#define FOO error
// should be no error since FOO should not be expanded
#pragma GCC FOO "foo"

