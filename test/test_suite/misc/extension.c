// #skip: diagnostics differ (aro_c3 gap)
__extension__;
__extension__ int a;

void foo(void) {
    __extension__ __auto_type a = 1;
    __extension__; // #error@18: expected expression
    __extension__ 1; // #warning@19: expression result unused [-Wunused-value]
}

struct Foo {
    __extension__; // #error@18: expected record declaration
    __extension__ int a;
};

#pragma GCC diagnostic warning "-Wextra-semi"

; // #warning@1: extra ';' outside of a function [-Wextra-semi]

__extension__;
__extension__ __extension__ _Static_assert(1, "");

__extension__ // #error@14: expected external declaration

