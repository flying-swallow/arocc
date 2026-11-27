// #skip: diagnostics differ (aro_cc gap)
// #opt: --target=x86_64-linux -std=c23 -fdeclspec
// #todo: TODO: implement 'access' attribute
// #todo: TODO: implement 'alias' attribute
// #todo: TODO: implement 'assume_aligned' attribute
// #todo: TODO: implement 'pure' attribute
// #todo: TODO: implement 'simd' attribute
// #todo: TODO: add error for standard decl attribute in type position
void cleanup_fn(void) {}
void foo(void) {
    int __attribute__((access)) bar_1; // #warning@24: TODO: implement 'access' attribute
    int __attribute__((access(foo, 0))) bar_2; // #warning@24: TODO: implement 'access' attribute
    int __attribute__((access(read_only, 1, 2))) bar_3; // #warning@24: TODO: implement 'access' attribute
    int __attribute__((alias(bar))) bar_4; // #error@30: use of undeclared identifier 'bar'
    int __attribute__((alias("bar"))) bar_5; // #warning@24: TODO: implement 'alias' attribute
    int __attribute__((aligned)) bar_6;
    int __attribute__((aligned(2 + 2))) bar_7;
    int __attribute__((aligned(4, 8))) bar_8; // #error@24: 'aligned' attribute takes at most 1 argument(s)
    int __attribute__((aligned(10))) bar_9; // #error@24: requested alignment is not a power of 2
    int __attribute__((assume_aligned(10, 0))) bar_10; // #warning@24: TODO: implement 'assume_aligned' attribute
    int __attribute__((assume_aligned(2))) bar_11; // #warning@24: TODO: implement 'assume_aligned' attribute
    int __attribute__((assume_aligned(2, 0))) bar_12; // #warning@24: TODO: implement 'assume_aligned' attribute
    int __attribute__((hot, pure)) bar_13; // #warning@24: 'hot' attribute only applies to functions [-Wignored-attributes] // #warning@29: TODO: implement 'pure' attribute
    int __attribute__((cleanup(cleanup_fn))) bar_14; // #error@24: 'cleanup' function 'cleanup_fn' must take 1 parameter
    int __attribute__((cleanup("cleanup_fn"))) bar_15; // #error@32: expected an identifier as argmuent of 'cleanup' attribute but got a string
    int __attribute__((simd())) bar_16; // #warning@24: TODO: implement 'simd' attribute
    int __attribute__((simd("inbranch"))) bar_17; // #warning@24: TODO: implement 'simd' attribute
    int __attribute__((simd("wrong"))) bar_18; // #warning@24: TODO: implement 'simd' attribute
    int __attribute__((invalid_attribute)) bar_19; // #warning@24: unknown attribute 'invalid_attribute' ignored [-Wunknown-attributes]
    int __attribute__((invalid_attribute(1, (2 + 3)))) bar_20; // #warning@24: unknown attribute 'invalid_attribute' ignored [-Wunknown-attributes]
    int __attribute__((deprecated("deprecated", 1))) bar_21; // #error@49: expected a string as argmuent of 'deprecated' attribute but got an integer constant
}

struct S {
    int __attribute__((cold)) x; // #warning@24: 'cold' attribute only applies to functions [-Wignored-attributes]
};

int __thiscall bar(int); // #warning@5: '__thiscall' calling convention is not supported for this target [-Wignored-attributes]
int big __attribute__((vector_size(4294967296))); // #error@36: attribute 'vector_size' argument value '4294967296' out of range
typedef float f2v __attribute__((vector_size(8.0i))); // #error@46: expected an integer constant as argmuent of 'vector_size' attribute but got a complex floating point number

typedef struct {} A1, __declspec(deprecated) B1, C1; // #error@23: a declspec attribute cannot appear here
typedef struct {} A2, __attribute__((deprecated)) B2, C2;
typedef struct {} A3, [[deprecated]] B3, C3; // #error@23: an attribute list cannot appear here

int standard_attr_on_types = sizeof(int [[noreturn, gnu::noreturn]]); // #error@43: 'noreturn' attribute cannot be applied to types // #error@53: 'gnu::noreturn' attribute cannot be applied to types
// int [[noreturn]] standard_attr_on_types2; // TODO

