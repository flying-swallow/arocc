// #kind: expand_error
#if !__has_warning("-Wextern-initializer")
#error
#endif

#if __has_warning("-Wfoo")
#error foo should not exist
#elif !__has_warning("-Wunrea" "chable-code")
#error unreachable-code should exist
#endif

#if __has_warning("foobar") // #warning@19: __has_warning expected option name (e.g. "-Wundef") [-Wmalformed-warning-check]
#error
#elif __has_warning(foobar) // #error@21: expected string literal in '__has_warning'
#error
#endif

#define X __has_warning("-Wextern-initializer")
_Static_assert(X == 1, "Failed to find warning");

