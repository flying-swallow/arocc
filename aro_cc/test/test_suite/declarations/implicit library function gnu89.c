// #opt: -std=gnu89
/* Before C99 an undeclared function is implicitly declared silently
   (gcc.c-torture/compile/920625-2.c), but a known library function still warns
   like Clang (-Wimplicit-function-declaration); `g` stays silent. */
int f(void) { return strlen("a") + g(); } // #warning@22: implicitly declaring library function 'strlen' [-Wimplicit-function-declaration] // #note@22: include the header <string.h> or explicitly provide a declaration for 'strlen'
