// #kind: expand_error
// #opt: -std=c17
#if !__is_identifier(typeof)
#error typeof should be an identifier in c17
#endif

#if __is_identifier(inline)
#error inline should not be an identifier in c17
#endif

#if __is_identifier(for)
#error for is not an identifier
#endif

#if __is_identifier("foo")
#error string should not be an identifier
#endif

#if __is_identifier(_Static_assert)
#error static assert is reserved
#endif

#define X __is_identifier(foobar)
_Static_assert(X == 1, "'foobar' should be an identifier");

#if __is_identifier(foo bar) // #error@25: missing ')', after builtin feature-check macro
#error too many arguments
#endif

#if __is_identifier() // #error@5: expected 1 argument(s) got 0
#error not enough arguments
#endif

#define FOO &
#if !__is_identifier(FOO)
#error FOO is an identifier
#endif

