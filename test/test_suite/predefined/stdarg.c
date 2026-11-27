// #skip: diagnostics differ (aro_cc gap)
// #note: stdarg.h:12:52: expanded from here
// #note: stdarg.h:12:29: expanded from here
// #note: stdarg.h:12:29: expanded from here
// #note: stdarg.h:12:29: expanded from here
#include <stdarg.h>
void foo(int a, ...) {
    va_list va, new;
    va_start(va, a);
    int arg = va_arg(va, int);
    va_copy(va, new);
    va_end(va);
}
void bar(int a, int b, ...) {
    va_list va;
    va_start(va, a); // #warning@5: second argument to 'va_start' is not the last named parameter [-Wvarargs] // #note@18: expanded from here
}
void baz(int a) {
    va_list va;
    va_start(va, a); // #error@5: 'va_start' used in a function with fixed args
}
va_list va;
int a = va_start(va, 1); // #error@9: 'va_start' cannot be used outside a function // #error@9: initializing 'int' from incompatible type 'void'
int b = __builtin_va_end; // #error@9: builtin function must be directly called
int c = __builtin_foo(); // #error@9: use of unknown builtin '__builtin_foo' [-Wimplicit-function-declaration]

