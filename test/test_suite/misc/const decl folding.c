// #skip: diagnostics differ (aro_c3 gap)
#pragma GCC diagnostic warning "-Wgnu-folding-constant"

const int x = 1;
int y = 2;

struct S {
    int bits: x; // #warning@15: expression is not an integer constant expression; folding it to a constant is a GNU extension [-Wgnu-folding-constant]
    int more_bits: y; // #error@20: expression is not an integer constant expression
};

enum E {
    FOO = x, // #warning@11: expression is not an integer constant expression; folding it to a constant is a GNU extension [-Wgnu-folding-constant]
    BAR = y, // #error@11: enum value must be an integer constant expression
};

void foo(void) {
    int array[] = {[x+10] = 1}; // #warning@21: expression is not an integer constant expression; folding it to a constant is a GNU extension [-Wgnu-folding-constant]
    int array2[] = {[y] = 1}; // #error@22: expression is not an integer constant expression
    _Static_assert(sizeof(array) == sizeof(array[0]) * (1 + 10 + 1), "wrong size");
}

_Static_assert(x == 1, "allowed"); // #warning@16: expression is not an integer constant expression; folding it to a constant is a GNU extension [-Wgnu-folding-constant]
int _Alignas(x) not_allowed; // #error@14: expected an integer constant as argmuent of '_Alignas' attribute but got an expression

void switch_fn(int param) {
    switch (param) {
        case x: return; // #warning@14: expression is not an integer constant expression; folding it to a constant is a GNU extension [-Wgnu-folding-constant] // #note@14: previous case defined here
        case 1: return; // #error@14: duplicate case value '1'
    }
}

void builtin_choose(void) {
    int var1, var2;
    __builtin_choose_expr(x, var1, var2) = 10; // #error@27: '__builtin_choose_expr' requires a constant expression
}

void bar(void) {
    int array[x+1] = {0}; // #warning@15: variable length array folded to constant array as an extension [-Wgnu-folding-constant]
    _Static_assert(sizeof(array) == 2*sizeof(int), "wrong size");
}

#pragma GCC diagnostic warning "-Wstring-conversion"
_Static_assert("", ""); // #warning@16: implicit conversion turns string literal into bool: 'char [1]' to '_Bool' [-Wstring-conversion] // #error@16: static assertion expression is not an integral constant expression
_Static_assert(!"", ""); // #error@16: static assertion failed due to requirement '!""'

_Static_assert((void*)0, ""); // #error@16: static assertion expression is not an integral constant expression
_Static_assert((void*)1, ""); // #error@16: static assertion expression is not an integral constant expression

int arr[5];
_Static_assert(arr, ""); // #warning@16: address of array 'arr' will always evaluate to 'true' [-Wpointer-bool-conversion] // #error@16: static assertion expression is not an integral constant expression
_Static_assert(!arr, ""); // #error@16: static assertion failed due to requirement '!arr'

_Static_assert(4.2, ""); // #warning@16: implicit conversion from 'double' to '_Bool' changes value from 4.2 to true [-Wfloat-conversion] // #error@16: static assertion expression is not an integral constant expression

