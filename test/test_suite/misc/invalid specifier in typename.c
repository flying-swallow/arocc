// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c23
int a = sizeof(int inline long inline long); // #error@20: type name does not allow function specifier to be specified // #error@32: type name does not allow function specifier to be specified
int b = sizeof(int typedef); // #error@20: type name does not allow storage class specifier to be specified
int c = sizeof(int constexpr); // #error@20: type name does not allow constexpr specifier to be specified
int d = sizeof(int __auto_type); // #error@20: cannot combine with previous 'int' specifier

enum A: _Noreturn { // #error@9: type name does not allow function specifier to be specified // #error@19: expected a type
    A
};

_Static_assert(__builtin_types_compatible_p(static int, int), ""); // #error@45: type name does not allow storage class specifier to be specified

