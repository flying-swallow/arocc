// #skip: diagnostics differ (aro_cc gap)
struct S {
    does_not_exist x; // #error@5: unknown type name 'does_not_exist'
};

void foo(void) {
    struct S s = {0};
    bar(s.x); // #error@5: call to undeclared function 'bar'; ISO C99 and later do not support implicit function declarations [-Wimplicit-function-declaration]
}

