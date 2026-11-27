// #skip: diagnostics differ (aro_cc gap)
void foo(void) {
    1 = 1; // #error@7: expression is not assignable
    const int a = 2; // #note@15: variable 'a' declared const here
    a = 1; // #error@7: cannot assign to variable 'a' with const-qualified type 'const int'
    _Bool b;
    b = 5.5f; // #warning@7: implicit conversion from 'float' to '_Bool' changes value from 5.5 to true [-Wfloat-conversion]
    b = (int *)5L;
    b *= 5.5f;
    int c;
    c = a;
    c *= a;
    c = (int *)6L; // #warning@7: implicit pointer to integer conversion from 'int *' to 'int' [-Wint-conversion]
    c *= (int *)7L; // #error@7: invalid operands to binary expression ('int' and 'int *')
    float d;
    d = b;
    d ^= 4; // #error@7: invalid operands to binary expression ('float' and 'int')
    int *e;
    e = (int *)1L;
    e += 2;
    e *= 3; // #error@7: invalid operands to binary expression ('int *' and 'int')
    struct Foo {
        int a;
    } f, g;
    f = g;
    f *= g; // #error@7: invalid operands to binary expression ('struct Foo' and 'struct Foo')
    int arr[4];
    arr = 4; // #error@9: array type 'int [4]' is not assignable
    int *x;
    x = 0;
    x = (0);
    x = 2; // #warning@7: implicit integer to pointer conversion from 'int' to 'int *' [-Wint-conversion]
    volatile struct Foo h;
    h = f;
    char *i;
    i = x; // #warning@7: incompatible pointer types assigning to 'char *' from incompatible type 'int *' [-Wincompatible-pointer-types]
    {
        char *y = 0;
        int *z = y; // #warning@18: incompatible pointer types initializing 'int *' from incompatible type 'char *' [-Wincompatible-pointer-types]
        z = y; // #warning@11: incompatible pointer types assigning to 'int *' from incompatible type 'char *' [-Wincompatible-pointer-types]
    }
    {
        const int *y = 0;
        int *z = y; // #warning@18: initializing 'int *' from incompatible type 'const int *' discards qualifiers [-Wincompatible-pointer-types-discards-qualifiers]
        z = y; // #warning@11: assigning to 'int *' from incompatible type 'const int *' discards qualifiers [-Wincompatible-pointer-types-discards-qualifiers]
    }
    {
        char *x = 0;
        const char *y = x;
        y = x;
    }
    (int){1} = 1;
    (const int){2} = 1; // #error@20: expression is not assignable
    const int k[3]; // #note@15: variable 'k' declared const here
    k[2] = 1; // #error@10: cannot assign to variable 'k' with const-qualified type 'const int [3]'
    const int *l;
    *l = 1; // #error@8: expression is not assignable
    foo = 0; // #error@9: non-object type 'void (void)' is not assignable
}

int const* func(void);
void various_assignments_to_consts(
    const int a, // #note@15: variable 'a' declared const here
    const int *b // #note@16: variable 'b' declared const here // #note@16: variable 'b' declared const here // #note@16: variable 'b' declared const here
) {
    a = 1; // #error@7: cannot assign to variable 'a' with const-qualified type 'const int'
    b[2] = 2; // #error@10: cannot assign to variable 'b' with const-qualified type 'const int *'
    (b++)[2] = 2; // #error@14: cannot assign to variable 'b' with const-qualified type 'const int *'
    (((b - 1)))[2] = 2; // #error@20: cannot assign to variable 'b' with const-qualified type 'const int *'
    struct C {
        int c;
    };
    const struct C c1; // #note@20: variable 'c1' declared const here
    const struct C *c2; // #note@21: variable 'c2' declared const here
    c1.c = 3; // #error@10: cannot assign to variable 'c1' with const-qualified type 'const struct C'
    c2->c = 4; // #error@11: cannot assign to variable 'c2' with const-qualified type 'const struct C *'

    struct Dummy { int a; };
    const struct Dummy d[1]; // #note@24: variable 'd' declared const here
    d[0].a = 1; // #error@12: cannot assign to variable 'd' with const-qualified type 'const struct Dummy [1]'

    const int arr[2][2] = { 0, 1, 2, 3}; // #note@15: variable 'arr' declared const here
    arr[0][0] = 1; // #error@15: cannot assign to variable 'arr' with const-qualified type 'const int [2][2]'

    struct Outer { struct Dummy a; };
    const struct Outer nested_struct = {1}; // #note@24: variable 'nested_struct' declared const here
    nested_struct.a.a = 2; // #error@23: cannot assign to variable 'nested_struct' with const-qualified type 'const struct Outer'

    func()[0] = 1; // #error@15: cannot assign to variable 'func' with const-qualified type 'const int *(void)'
}

void bar(void) {
    int *a;
    void *b;
    a = b;
    b = a;
}

void baz(void) {
    enum E e; // #error@12: variable has incomplete type 'enum E'
    e = 0;
}

int qux(void) {
    typedef const int A;
    A a; // #note@7: variable 'a' declared const here
    a = 1; // #error@7: cannot assign to variable 'a' with const-qualified type 'const A' (aka 'const int')
    return a;
}

void different_sign(void) {
    int x = 0;
    unsigned int *y;
    y = &x; // #warning@7: incompatible pointer types assigning to 'unsigned int *' from incompatible type 'int *' converts between pointers to integer types with different sign [-Wpointer-sign]
}

void constant_sign_conversion(void) {
    unsigned char x = 1000; // #warning@23: implicit conversion from 'int' to 'unsigned char' changes value from 1000 to 232 [-Wconstant-conversion]

#pragma GCC diagnostic push
#pragma GCC diagnostic warning "-Wsign-conversion"
    unsigned int u = -1; // #warning@22: implicit conversion changes signedness: 'int' to 'unsigned int' [-Wsign-conversion]
#pragma GCC diagnostic pop
}

void assign_cast(void) {
    int a;
    (float)a = 1.2f; // #error@14: assignment to cast is not allowed
}

void assign_incomplete(void) {
    typedef struct S S;
    extern S s;
    s = 1; // #error@7: incomplete type 'S' (aka 'struct S') is not assignable
}

