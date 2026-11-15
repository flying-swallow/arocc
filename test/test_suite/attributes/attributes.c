// #skip: diagnostics differ (aro_c3 gap)
// #opt: -Wno-deprecated-non-prototype -Wc23-extensions -std=gnu17
// #todo: TODO: implement 'mode' attribute
// #todo: TODO: implement 'format' attribute
enum E {
  unavailable __attribute__((unavailable)) = 0,
  oldval __attribute__((deprecated)),
  newval
};

void foo(void) {
    int a __attribute__((noreturn)); // #warning@26: 'noreturn' attribute only applies to functions [-Wignored-attributes]
    int b __attribute__((does_not_exist(4))); // #warning@26: unknown attribute 'does_not_exist' ignored [-Wunknown-attributes]
    int c __attribute__((aligned(16)));
    int d __attribute__((aligned(4 + 4 + 4 + 4)));

    int e __attribute__((aligned(4)));
    int __attribute__((aligned(4))) f;
    __attribute__((aligned(4))) int g;

    __attribute__(()) int h;
    __attribute__((aligned(4), unused)) int i;
    __attribute__((aligned(4), unused, uninitialized)) int j; // #warning@40: unknown attribute 'uninitialized' ignored [-Wunknown-attributes]
    __attribute__((mode(__byte__))) int k; // #warning@20: TODO: implement 'mode' attribute

    __attribute__((section("mysegment,mysection"))) static int l; // #warning@20: 'section' attribute only applies to functions and global variables [-Wignored-attributes]
}

int bar(void) {
Label:
    __attribute__((deprecated)); // #error@20: 'deprecated' attribute cannot be applied to a statement
    return 0;

ErrorHandling:
    __attribute__((__hot__, cold(), __unused__())); // #error@29: 'cold' and 'hot' attributes are not compatible // #note@20: conflicting attribute is here
    return 1;
}

void bad_fallthrough(void) {
    __attribute__((fallthrough)); // #error@20: 'fallthrough' attribute outside a switch statement
}

void invalid_statement_attribute(void) {
    __attribute__((noreturn)); // #error@20: 'noreturn' attribute cannot be applied to a statement
}

void qux(int x) {
    switch (x) {
        case 1:
            bar();
            __attribute__((fallthrough));
        case 2:
            __attribute__((fallthrough));
        default:
            return;
    }
}

__attribute__((format(printf, 2, 3))) __attribute__((noreturn)) void my_printf (void *my_object, const char *my_format, ...); // #warning@16: TODO: implement 'format' attribute
__attribute__((noreturn, format(printf, 2, 3), hot)) void my_printf1 (void *my_object, const char *my_format, ...); // #warning@26: TODO: implement 'format' attribute
__attribute__((format(printf, 2, 3))) void my_printf2 (void *my_object, const char *my_format, ...); // #warning@16: TODO: implement 'format' attribute
__attribute__((format(printf, 2, 3), noreturn)) void my_printf3 (void *my_object, const char *my_format, ...); // #warning@16: TODO: implement 'format' attribute

struct S1 { int x; } __attribute__ ((aligned (8)));
struct __attribute__ ((aligned (8))) S2 { int x; };
union U1 { int x; int y; } __attribute__ ((aligned (8)));
union __attribute__ ((aligned (8))) U2 { int x; int y; };
enum E1 { FOO } __attribute__ ((aligned (8)));
enum __attribute__ ((aligned (8))) E2 { BAR };

void vectors(void) {
    __attribute__ ((vector_size (32))) typedef __attribute__ ((aligned (32))) int int_vec32_t0;
    typedef __attribute__ ((vector_size (32))) int int_vec32_t1;
    typedef int __attribute__ ((vector_size (32))) int_vec32_t2;
    typedef int int_vec32_t3 __attribute__ ((vector_size (32)));
}

void diagnostics(void) {
    int __attribute__((aligned(4))) x;
    x(0); // #error@6: cannot call non function type 'int'
}

void math(void) {
    int __attribute__((aligned(4))) x = 0;
    (void) (x / 2);
}

extern int abs (int __x) __attribute__((__noreturn__ )) __attribute__((__const__));

typedef int X();
X x __attribute__((cold));

typedef struct {
  __attribute__((__aligned__(__alignof__(long long)))) long long __clang_max_align_nonce1, __attribute__((packed)) nonce2, nonce3;
  long double __clang_max_align_nonce2
      __attribute__((__aligned__(__alignof__(long double))));
} max_align_t;

__attribute__((unused)) void attributed_old_style_func(baz)
int baz;
{
}

_Static_assert(sizeof(struct S2) == 8, "sizeof aligned struct");
_Static_assert(_Alignof(union U1) == 8, "_Alignof aligned union");

typedef struct {
    short i:1 __attribute__((aligned(8)));
} A;

__attribute__((aligned(32))) char aligned_arr[] = {1, 2, 3};
_Static_assert(sizeof(aligned_arr) == 3, "");

__attribute__((section(1))) int Z; // #error@24: expected a string as argmuent of 'section' attribute but got an integer constant

__attribute__((void)) int a; // #warning@16: unknown attribute 'void' ignored [-Wunknown-attributes]

int (__attribute__((aligned)) a);

[[deprecated("foo")]] int c23_extension; // #warning@1: [[]] attributes are a C23 extension [-Wc23-extensions]

void gnu_label_attribute(int x) {
    foo:
    __attribute__((unused, hot)) // #warning@5: GNU-style attribute between label and declaration applies to the label [-Wlabel-attribute]
    int a; // #warning@5: label followed by a declaration is a C23 extension [-Wc23-extensions]
}

__attribute__((fallthrough)) int fallthrough_on_decl; // #error@16: 'fallthrough' attribute cannot be applied to a declaration

__attribute__(()) // test attribute at eof // #error@18: expected external declaration

