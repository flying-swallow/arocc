// #skip: diagnostics differ (aro_cc gap)
// #opt: -Wno-implicit-int
_Alignas(2) int foo(void); // #error@1: '_Alignas' attribute only applies to variables and fields
typedef int F(void);
F _Alignas(2) bar; // #error@3: '_Alignas' attribute only applies to variables and fields
_Alignas(0) int a; // #error@1: requested alignment is not a power of 2
_Alignas(1) int b; // #error@1: requested alignment is less than minimum alignment of 4
_Alignas(3) int c; // #error@1: requested alignment is not a power of 2

int baz(_Alignas(8) int d) { // #error@9: '_Alignas' attribute cannot be applied to a function parameter
    return _Alignof(_Alignas(8) int); // #warning@21: '_Alignas' attribute ignored when parsing type [-Wignored-attributes]
}

_Alignas(4294967297) int e; // #error@1: requested alignment of 4294967297 is too large
_Alignas(-2) int f; // #error@1: requested negative alignment of -2 is invalid

_Alignas(c) int x; // #error@10: expected an integer constant as argmuent of '_Alignas' attribute but got an expression

__attribute__((aligned)) char g;
__attribute__((aligned)) int h;
_Alignas(1) _Alignas(2) _Alignas(4) char i;
__attribute__((aligned(2), aligned(4))) int j;
__attribute__((aligned(8))) __attribute__((aligned(4))) int k;
__attribute__((aligned(16))) typeof(int[]) l  = {1};
typeof(int[]) __attribute__((aligned(16))) m  = {1};
typeof(int[]) n __attribute__((aligned(32))) = {1};

#pragma GCC diagnostic ignored "-Wgnu-alignof-expression"
_Static_assert(_Alignof(g) == _Alignof(h), "incorrect alignment");
_Static_assert(_Alignof(i) == 4, "incorrect alignment");
_Static_assert(_Alignof(j) == 4, "incorrect alignment");
_Static_assert(_Alignof(k) == 8, "incorrect alignment");
_Static_assert(_Alignof(l) == 16, "incorrect alignment");
_Static_assert(_Alignof(m) == 16, "incorrect alignment");
_Static_assert(_Alignof(n) == 32, "incorrect alignment");

__attribute__((aligned("foo"))) o; // #error@24: expected an integer constant as argmuent of 'aligned' attribute but got a string
_Alignas(1.2) p; // #error@10: expression is not an integer constant expression
_Static_assert(_Alignof(_BitInt(65535)) > 0, "");

void array_incomplete(void) {
    typedef int arr[] __attribute__((aligned(32)));
    arr a = {1, 2, 3};
    _Static_assert(_Alignof(__typeof(a)) == 4, "");
}

void array_fixed(void) {
    typedef int arr[3] __attribute__((aligned(32)));
    arr a = {1, 2, 3};
    _Static_assert(_Alignof(__typeof(a)) == 32, "");
}

void array_element_typedef(void) {
    typedef int triple[3];
    typedef triple elem __attribute__((aligned(8)));
    typedef elem arr[3];
    arr a = {{1, 2, 3}, {4, 5, 6}, {7, 8, 9}};
#if __ARO_EMULATE__ == __ARO_EMULATE_MSVC__
    _Static_assert(sizeof(arr) == 36, "");
#else
#   define ALIGN_UP(SIZE, ALIGN) (((SIZE) + (ALIGN) - 1) / (ALIGN) * (ALIGN))
    _Static_assert(sizeof(arr) == ALIGN_UP((sizeof(triple) / sizeof(int)) * sizeof(elem), _Alignof(arr)), "");
#endif
    _Static_assert(_Alignof(arr) == 8, "");
    _Static_assert(_Alignof(__typeof(a)) == 8, "");
}

void array_size_align_typedef(void) {
    typedef int elem __attribute__((aligned(8)));
    typedef elem arr[4]; // #error@21: size of array element of type 'elem' (aka 'int') (4 bytes) isn't a multiple of its alignment (8 bytes)
}

void register_var(void) {
    register _Alignas(8) int a; // #error@14: '_Alignas' attribute cannot be applied to a variable with 'register' storage class
}

