// #skip: diagnostics differ (aro_cc gap)
// #opt: -Wno-unused
void foo(void) {
    const volatile _Atomic long a;
    a | 2.f; // #error@7: invalid operands to binary expression ('const volatile _Atomic(long)' and 'float')
    (void)(a | (_Bool)2);
    (void)((char)a * 2.);
    (char)a * (int*)2; // #error@13: invalid operands to binary expression ('char' and 'int *')
    (void)(foo && (char)2);
    foo || (void)2; // #error@9: invalid operands to binary expression ('void (void)' and 'void')
    (void)((const int*)1 == (int *)1);
    (float*)1 == (int*)1; // #warning@15: comparison of distinct pointer types ('float *' and 'int *') [-Wcompare-distinct-pointer-types]
    1 == (int*)1; // #warning@7: comparison between pointer and integer ('int' and 'int *') [-Wpointer-integer-compare]
    1.0 == (int*)1; // #error@9: invalid operands to binary expression ('double' and 'int *')
    (_Complex double)1 < 1; // #error@24: invalid operands to binary expression ('_Complex double' and 'int')
    (void)((int*)1 + 2);
    (int*)1 + (int*)2; // #error@13: invalid operands to binary expression ('int *' and 'int *')
    (void)((int*)1 - 2);
    (void)((int*)1 - (int*)2);
    1 - (int*)2; // #error@7: invalid operands to binary expression ('int' and 'int *')
    (int*)1 - (float*)2; // #error@13: incompatible pointer types ('int *' and 'float *')
    1 ? (void)2 : 3;
    1 ? (int*)2 : 3; // #warning@17: implicit integer to pointer conversion from 'int' to 'int *' [-Wint-conversion]
    1 ? 2 : (int*)3; // #warning@11: implicit integer to pointer conversion from 'int' to 'int *' [-Wint-conversion]
    (void)(1 ? (int*)2 : (int*)3);
    (void)(1 ? (int*)2 : (float*)3); // #warning@24: pointer type mismatch ('int *' and 'float *') [-Wpointer-type-mismatch]
    (void)(1 ? (int*)2 : (const void*)3);
    (void)(1 ? (volatile int*)2 : (const void*)3);
    (void)(1 ? (const int *)1 : 0);
    (void)(1 ? 0 : (const int *)1);
    struct Foo { int a; } b;
    const struct Foo c;
    (void)(1 ? b : c);
    (void)(1 ? b : 1); // #error@18: invalid operands to binary expression ('struct Foo' and 'int')
    ?:; // #error@5: expected statement
    (void)(1 * (int)sizeof(int));
    int *ptr;
    char idx;
    ptr = ptr + idx;
    ,(void)1; // #error@5: expected expression
    (void)2,; // #error@13: expected expression
    (void)(ptr == 0);
    (void)(0 == ptr);
}

int bar(void) {
    return 1U < 2U;
}

int baz = 0xFFFFFFFFFFLL + 1u; // #warning@11: implicit conversion from 'long long' to 'int' changes non-zero value from 1099511627776 to 0 [-Wconstant-conversion]
int qux = 1/"foo"; // #error@12: invalid operands to binary expression ('int' and 'char [4]')
int quux = "foo"?1:2;

struct S { int x; };
void invalid_chained_comparisons() {
    struct S s = { .x = 1 };
    1.0 == s == 1; // #error@9: invalid operands to binary expression ('double' and 'struct S')
    1.0 < s == 1; // #error@9: invalid operands to binary expression ('double' and 'struct S')
    1.0 == &1 == 1; // #error@12: cannot take the address of an rvalue // #error@9: invalid operands to binary expression ('double' and 'int *')
}

void mod_assign_float(void) {
    int x = 1;
    x %= 1.0f; // #error@7: invalid operands to binary expression ('int' and 'float')
}

void binary_conditional(void) {
    (void)(1 ?: 2.);
    (void)1.2 ?: (void)2; // #error@15: used type 'void' where arithmetic or pointer type is required
}

struct Foo;
int invalid_ptr_arithmetic(struct Foo *num) {
    return num - num; // #error@16: arithmetic on a pointer to an incomplete type 'struct Foo'
}

void address_of_invalid_type(void) {
    char x[64];
    char *y = &(x&x);     // #error@18: invalid operands to binary expression ('char [64]' and 'char [64]')
}

_Static_assert((1 ^ -1) == -2, "");
_Static_assert((0 ^ 0) == 0, "");
_Static_assert((-1 ^ 0) == -1, "");
_Static_assert((-1 ^ -1) == 0, "");
_Static_assert((-2 ^ 2) == -4, "");

_Static_assert(2.0||(2.0 == 2.0), "");
_Static_assert(2.0||(3.0 > 2.0), "");
_Static_assert(2.0||(2.0 && 2.0), "");

_Static_assert((-10 & -1) == -10, "");

int invalid_conditional = sizeof(struct A) ? 1 : 2; // #error@27: invalid application of 'sizeof' to an incomplete type 'struct A'
int invalid_bin_conditional = sizeof(struct B) ? : 1; // #error@31: invalid application of 'sizeof' to an incomplete type 'struct B'
int invalid_div_by_zero = sizeof(struct C) / 0; // #error@27: invalid application of 'sizeof' to an incomplete type 'struct C'

void div_by_zero_assign(void) {
    int a = 1;
    a /= 0; // #warning@7: division by zero is undefined [-Wdivision-by-zero]
    (void)(0 && (a /= 0));
}

_Static_assert((int){1} = 0, ""); // #error@16: static assertion expression is not an integral constant expression

void qualified_binary_operands(void) {
    const volatile _Atomic(long) a;
    const volatile float b;
    volatile _Atomic(long) c;
    b | a; // #error@7: invalid operands to binary expression ('const volatile float' and 'const volatile _Atomic(long)')
    a | b; // #error@7: invalid operands to binary expression ('const volatile _Atomic(long)' and 'const volatile float')
    (long)a | b; // #error@13: invalid operands to binary expression ('long' and 'const volatile float')
    c |= b; // #error@7: invalid operands to binary expression ('volatile _Atomic(long)' and 'const volatile float')
}

void invalid_float_pointer_arithmetic(void) {
    int *ptr;
    int x;
    float f;
    x *= ptr; // #error@7: invalid operands to binary expression ('int' and 'int *')
    f /= ptr; // #error@7: invalid operands to binary expression ('float' and 'int *')
    1.0 * ptr; // #error@9: invalid operands to binary expression ('double' and 'int *')
    ptr / 1.0; // #error@9: invalid operands to binary expression ('int *' and 'double')
    ptr += x;
    ptr -= x;
}

