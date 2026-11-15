// #skip: diagnostics differ (aro_c3 gap)
// #opt: -Wno-unused -std=c23
int foo(void) {
    return sizeof(int) + _Alignof(float);
}

int bar(void) {
    return sizeof 2 + __alignof(float);
}

int baz(void) {
    return sizeof int + __alignof__ float; // #error@19: expected parentheses around type name // #error@37: expected parentheses around type name
}

int quux(void) {
    return sizeof 2 + _Alignof 2; // #warning@23: '_Alignof' applied to an expression is a GNU extension [-Wgnu-alignof-expression]
}

int quuux(void) {
    (void)sizeof(0/0);
    return __alignof(0/0);
}

_Static_assert(sizeof((void)1, (int*)0) == sizeof(int*), "sizeof");

_Static_assert(_Alignof(struct does_not_exist) == 0, ""); // #error@16: invalid application of 'alignof' to an incomplete type 'struct does_not_exist'

#pragma GCC diagnostic warning "-Wpointer-arith"
_Static_assert(sizeof(void) == 1, ""); // #warning@16: invalid application of 'sizeof' to a void type [-Wpointer-arith]
_Static_assert(_Alignof(void) == 1, ""); // #warning@16: invalid application of '_Alignof' to a void type [-Wpointer-arith]
void array_params(int x, int y[5], int z[x]) {
    _Static_assert(sizeof(y) == sizeof(int *), ""); // #warning@26: sizeof on array function parameter will return size of 'int *' instead of 'int [5]' [-Wsizeof-array-argument]
    _Static_assert(sizeof(z) == sizeof(int *), ""); // #warning@26: sizeof on array function parameter will return size of 'int *' instead of 'int [<expr>]' [-Wsizeof-array-argument]
}

void sizeof_compound_literal(void) {
    sizeof (int){2};
    _Alignof (int){2}; // #warning@5: '_Alignof' applied to an expression is a GNU extension [-Wgnu-alignof-expression]
    sizeof (static int){2};
    alignof (static int){2}; // #warning@5: 'alignof' applied to an expression is a GNU extension [-Wgnu-alignof-expression]
}

