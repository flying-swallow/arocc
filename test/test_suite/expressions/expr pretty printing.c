// #opt: -Wno-c23-extensions
int a;
#define FOO sizeof(a)
_Static_assert((int)(FOO == 5 + 1)); // #error@16: static assertion failed due to requirement '(int)(sizeof (a) == 5 + 1)' // #note@26: expression evaluates to '4 == 6'
typedef int *F;
_Static_assert((int)(sizeof(F) == 5)); // #error@16: static assertion failed due to requirement '(int)(sizeof(int *) == 5)' // #note@32: expression evaluates to '8 == 5'
_Static_assert(__builtin_types_compatible_p(int, long)); // #error@16: static assertion failed due to requirement '__builtin_types_compatible_p(int, long)'
_Static_assert(_Generic(1, int: 0, default: 2) == 1); // #error@16: static assertion failed due to requirement '_Generic(1, default: 2, int: 0) == 1' // #note@48: expression evaluates to '0 == 1'
_Static_assert(__builtin_constant_p(1) == 0); // #error@16: static assertion failed due to requirement '__builtin_constant_p(1) == 0' // #note@40: expression evaluates to '1 == 0'
_Static_assert((1 ? : 3) == 0x2); // #error@16: static assertion failed due to requirement '(1 ?: 3) == 0x2' // #note@26: expression evaluates to '1 == 2'
_Static_assert((1 ? 4 : 3) == 2.4f); // #error@16: static assertion failed due to requirement '(1 ? 4 : 3) == 2.4f' // #note@28: expression evaluates to '4 == 2.4'
_Static_assert(__builtin_choose_expr(1,2,3) == 0); // #error@16: static assertion failed due to requirement '__builtin_choose_expr(1, 2, 3) == 0' // #note@45: expression evaluates to '2 == 0'
_Static_assert('\x60' == 1); // #error@16: static assertion failed due to requirement ''\x60' == 1' // #note@23: expression evaluates to '96 == 1'
_Static_assert('abcd' == 1); // #error@16: static assertion failed due to requirement ''abcd' == 1' // #note@23: expression evaluates to '1633837924 == 1'

