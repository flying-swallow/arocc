// #skip: diagnostics differ (aro_c3 gap)
// #opt: -Wno-gnu-alignof-expression -I include
#include "test_helpers.h"
__auto_type __attribute__((noreturn)) foo(void); // #error@1: '__auto_type' not allowed in function return type
__auto_type foo1(void) {} // #error@1: '__auto_type' not allowed in function return type

void bar(__auto_type); // #error@10: '__auto_type' not allowed in function prototype
void bar1(__auto_type x) {} // #error@11: '__auto_type' not allowed in function prototype

typedef __auto_type my_auto_type; // #error@9: '__auto_type' not allowed in typedef
int __auto_type a = 5; // #error@5: cannot combine with previous 'int' specifier

struct S {
    unsigned bitfield: 5;
};
struct BadStruct {
    __auto_type y; // #error@5: '__auto_type' not allowed in struct member
};
union BadUnion {
    __auto_type x; // #error@5: '__auto_type' not allowed in union member
};

int myfunc(int x) { return x; }

void baz(void) {

#   pragma GCC diagnostic push
#   pragma GCC diagnostic warning "-Wgnu-auto-type"
#   pragma GCC diagnostic ignored "-Wsizeof-array-argument"
    __auto_type decayed_arr = (double[]){1.,2.,3.,4.,5.}; // #warning@5: '__auto_type' is a GNU extension [-Wgnu-auto-type]
    _Static_assert(sizeof(decayed_arr) == sizeof(double *), "");
#   pragma GCC diagnostic pop

    __auto_type b = 5U;
    EXPECT_TYPE(b, unsigned);
    int c = (__auto_type)5; // #error@14: expected expression

    __auto_type d; // #error@17: declaration of variable 'd' with deduced type requires an initializer

    __auto_type e = 1, f = 2, j = 3; // #error@5: '__auto_type' may only be used with a single declarator

    struct S s = {};
    __auto_type g = s.bitfield; // #error@21: cannot use bit-field as '__auto_type' initializer

    const int const_int = 5;
    __auto_type h = const_int;
    h = 100;

    const __auto_type i = 0; // #note@23: variable 'i' declared const here
    i += 1; // #error@7: cannot assign to variable 'i' with const-qualified type 'const int'

    __auto_type func_ptr = myfunc;
    EXPECT_TYPE(func_ptr, __typeof__(&myfunc));
    EXPECT_TYPE(func_ptr, int (*)(int));

    __auto_type my_struct = (struct S){.bitfield = 10 };
    EXPECT_TYPE(my_struct, struct S);

    __auto_type auto_array[2] = {1, 2}; // #error@5: 'auto_array' declared as array of '__auto_type'

    __auto_type init_list = {1,2}; // #error@29: cannot use '__auto_type' with initializer list

    __attribute__((aligned(128))) __auto_type aligned_var = 0ULL;
    _Static_assert(_Alignof(aligned_var) == 128, "");
}

__auto_type multidimensional[2][2]; // #error@1: 'multidimensional' declared as array of '__auto_type'

auto int invalid_c23_auto = 1; // #error@30: 'auto' specified on global variable

