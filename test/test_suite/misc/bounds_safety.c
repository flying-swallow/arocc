// #skip: diagnostics differ (aro_c3 gap)
// #opt: -fexperimental-bounds-safety
// #todo: TODO: reimplement bounds safety attributes
// #note: ptrcheck.h:11:33: expanded from here
// #note: ptrcheck.h:11:33: expanded from here
// #note: ptrcheck.h:11:33: expanded from here
// #note: ptrcheck.h:11:33: expanded from here
// #note: ptrcheck.h:11:33: expanded from here
// #note: ptrcheck.h:12:43: expanded from here
// #note: ptrcheck.h:12:43: expanded from here
#include <ptrcheck.h>

#if !__has_ptrcheck
#error bounds safety feature not found!
#endif

void foo(void) {
    int *__single p; // #warning@10: TODO: implement 'single' attribute
    int __single i; // #warning@9: TODO: implement 'single' attribute

    p[0] = 5;
    0[p] = 10;
    *p = 1;
    1[p] = 10;
    p[1] = 10;
    int *p2;
    p2 = p + 1;
    p2 = p - 1;
    p++;
    ++p;
    p--;
    --p;
    p += 1;
    p -= 1;
}

int __single __single *redundant; // #warning@5: TODO: implement 'single' attribute // #warning@14: TODO: implement 'single' attribute

int __single __unsafe_indexable *multiple; // #warning@5: TODO: implement 'single' attribute // #warning@14: TODO: implement 'unsafe_indexable' attribute

void unsafe_indexable(void) {
    int *__unsafe_indexable p; // #warning@10: TODO: implement 'unsafe_indexable' attribute
    p[100] = 5;
}

void typeechecking(void) {
    int a, b;
    a[b] = 5; // #error@6: subscripted value is not an array, pointer or vector
}

