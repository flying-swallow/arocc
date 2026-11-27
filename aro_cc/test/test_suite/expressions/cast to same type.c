// #skip: diagnostics differ (aro_cc gap)
// #opt: -pedantic
struct S {
    int x;
};

void foo(void) {
    struct S s = {.x = 5 };
    s = (struct S)s; // #warning@9: C99 forbids casting nonscalar type 'struct S' to the same type [-Wpedantic]
}

