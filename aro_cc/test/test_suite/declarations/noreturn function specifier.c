// `_Noreturn` is a function specifier in any declaration-specifier position
// (file scope, after storage class, block scope, via <stdnoreturn.h>).
#include <stdnoreturn.h>
_Noreturn void a(void);
static _Noreturn void b(void) { for (;;) {} }
void _Noreturn c(void);
noreturn void d(void);
void use(void) { _Noreturn void e(void); (void)b; }
_Noreturn _Noreturn void f(void); // #warning@11: duplicate '_Noreturn' declaration specifier
struct S { _Noreturn int x; }; // #error@12: expected record declaration // #warning@12: 'noreturn' attribute only applies to functions
