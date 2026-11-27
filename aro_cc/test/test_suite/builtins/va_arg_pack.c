extern int foo(int, ...);
int a = __builtin_va_arg_pack(); // #error@9: '__builtin_va_arg_pack' cannot be used outside a function
int b = __builtin_va_arg_pack_len(); // #error@9: '__builtin_va_arg_pack_len' cannot be used outside a function

void bar(int arg) {
    int a = __builtin_va_arg_pack(); // #error@13: '__builtin_va_arg_pack' used in a function with fixed args
    int b = __builtin_va_arg_pack_len(); // #error@13: '__builtin_va_arg_pack_len' used in a function with fixed args
}

void baz(int arg, ...) {
    int a = __builtin_va_arg_pack(); // #error@13: '__builtin_va_arg_pack' used in a function that is not always inlined
    int b = __builtin_va_arg_pack_len(); // #error@13: '__builtin_va_arg_pack_len' used in a function that is not always inlined
}

inline __attribute__((always_inline))
int qux(int a, ...) {
    a = __builtin_va_arg_pack_len();
    bar((__builtin_va_arg_pack())); // #error@10: '__va_arg_pack' passed to non-variadic function
    (void)foo((__builtin_va_arg_pack())); // #error@16: '__va_arg_pack' passed as non-variadic argument
    (void)foo(1, (__builtin_va_arg_pack()), 1); // #error@19: '__va_arg_pack' is not the final argument
    return foo(1, (__builtin_va_arg_pack()));
}

void quuuuuuu(void) {
    (void)qux(1, 2);
}

