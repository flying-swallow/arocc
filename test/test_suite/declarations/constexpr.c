// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c23 -Wpedantic
// #todo: TODO constexpr record field access
constexpr int a = 1;
static constexpr int b = 2;
thread_local constexpr int c = 3; // #error@14: cannot combine with previous 'thread_local' specifier

constexpr int foo(constexpr int param) { // #error@19: invalid storage class on function parameter // #error@1: illegal storage class on function
    auto constexpr a = 1;
    register constexpr int b = 2;
    return b;
}

constexpr _BitInt(b) bit = 4; // #warning@28: implicit conversion from 'int' to 'signed _BitInt(2)' changes non-zero value from 4 to 0 [-Wconstant-conversion]

int non_const = 4;
constexpr int invalid = non_const; // #error@25: constexpr variable must be initialized by a constant expression

constexpr bool const_bool_true = true;
static_assert(const_bool_true);
constexpr bool const_bool_false = false;
static_assert(!const_bool_false);

struct S {
    int x;
    int y;
};

constexpr struct S s1 = { 1, 2};
constexpr struct S s2 = { 1, a};
constexpr struct S s3 = { 1, non_const}; // #error@30: constexpr variable must be initialized by a constant expression
// constexpr int s1_x = s1.x;

