// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c23
// #note: stddef.h:17:14: expanded from here
#include <stddef.h>
void foo(int x[static 10]) { // #note@14: callee declares array parameter as static here // #note@14: callee declares array parameter as static here // #note@14: callee declares array parameter as static here

}

void bar(void) {
    foo(NULL); // #warning@9: null passed to a callee that requires a non-null argument [-Wnonnull]
    foo(nullptr); // #warning@9: null passed to a callee that requires a non-null argument [-Wnonnull]
    foo(0); // #warning@9: null passed to a callee that requires a non-null argument [-Wnonnull]
}

