// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c23
// #todo: TODO clang allows nullptr to bool cast
#include <stddef.h>
// Comments below from N3047 working draft — August 4, 2022 § 7.21.2
// Because it is considered to be a scalar type, nullptr_t may appear in any context where (void*)0 would be valid,
// for example,
// — as the operand of alignas, sizeof or typeof operators,
// — as the operand of an implicit or explicit conversion to a pointer type,
// — as the assignment expression in an assignment or initialization of an object of type nullptr_t,
// — as an argument to a parameter of type nullptr_t or in a variable argument list,
// — as a void expression,
// — as the operand of an implicit or explicit conversion to bool,
// — as an operand of a _Generic primary expression,
// - as an operand of the !, &&, || or conditional operators, or
// — as the controlling expression of an if or iteration statement.

static_assert(sizeof(nullptr) == sizeof(char *));
static_assert(alignof(nullptr_t) == alignof(char *));
static_assert(!nullptr);
static_assert(nullptr || true);
static_assert(!(nullptr && true));
static_assert(nullptr == nullptr);
static_assert(!(nullptr && nullptr));
static_assert(nullptr == false);
static_assert(nullptr == 0);
static_assert(nullptr ? 0 : 1);
static_assert(nullptr || 1);
static_assert(nullptr ? 0 : 1);

void foo(nullptr_t param) {
    char *p1 = nullptr;
    char *p2 = (nullptr_t) nullptr;
    p2 = nullptr;
    nullptr_t p3 = nullptr;
    p3 = nullptr;
    const int *p4 = nullptr;
    p4 = nullptr;
    float (*p5)(int) = nullptr;
}

void bar(int param1, ...) {

}

void generic_nullptr(void) {

}
void generic_int(int x) {

}
void generic_ptr(void *p) {

}

void baz(void) {
    foo(nullptr);
    nullptr_t nullptr_t_var = nullptr;
    foo(nullptr_t_var);
    bar(0, nullptr);
    nullptr_t_var = (nullptr_t)nullptr;
    (void)nullptr;
    bool b = (bool)nullptr;
    b = !nullptr;

    if (nullptr){}
    while (nullptr){ break; }
    for (; nullptr; ){ break; }

    _Generic(nullptr,
        nullptr_t: generic_nullptr,
        int: generic_int,
        void *: generic_ptr
    )();
    _Generic(0,
        nullptr_t: generic_nullptr,
        int: generic_int,
        void *: generic_ptr
    )(0);
    _Generic((void*)0,
        nullptr_t: generic_nullptr,
        int: generic_int,
        void *: generic_ptr
    )(0);

    void *vp = 1 ? nullptr : nullptr;
    vp = 1 ? nullptr : &b;
}

void bad_nullptr_use(void) {
    static_assert(nullptr != 1); // #error@27: invalid operands to binary expression ('nullptr_t' and 'int')
    static_assert(nullptr != true); // #error@27: invalid operands to binary expression ('nullptr_t' and 'bool')
    bool b = nullptr; // TODO clang allows this // #error@14: initializing 'bool' from incompatible type 'nullptr_t'
    int x = nullptr; // #error@13: initializing 'int' from incompatible type 'nullptr_t'
    nullptr_t p = 0; // #error@19: initializing 'nullptr_t' from incompatible type 'int'
    float f = (float)nullptr; // #error@15: cannot cast an object of type 'nullptr_t' to 'float'
    x = (int)nullptr; // #error@9: cannot cast an object of type 'nullptr_t' to 'int'
    void *vp = 1 ? nullptr : 0; // #error@28: invalid operands to binary expression ('nullptr_t' and 'int')
    nullptr > 1; // #error@13: invalid operands to binary expression ('nullptr_t' and 'int')
    nullptr > 1.0; // #error@13: invalid operands to binary expression ('nullptr_t' and 'double')
    nullptr == 1; // #error@13: invalid operands to binary expression ('nullptr_t' and 'int')
    nullptr == 1.0; // #error@13: invalid operands to binary expression ('nullptr_t' and 'double')
    nullptr & 1; // #error@13: invalid operands to binary expression ('nullptr_t' and 'int')
    nullptr + 1; // #error@13: invalid operands to binary expression ('nullptr_t' and 'int')
    p + 1; // #error@7: invalid operands to binary expression ('nullptr_t' and 'int')
    nullptr - 1; // #error@13: invalid operands to binary expression ('nullptr_t' and 'int')
    vp = (nullptr_t)0; // #error@10: cannot cast an object of type 'int' to 'nullptr_t'
    vp = (nullptr_t)(void *)0; // #error@10: cannot cast an object of type 'void *' to 'nullptr_t'
}

