// #skip: diagnostics differ (aro_c3 gap)
struct Foo {
    int a;
};

extern void b(_Bool b); // #note@21: passing argument to parameter here
extern void i(int); // #note@15: passing argument to parameter here
extern void f(float); // #note@15: passing argument to parameter here
extern void ip(int *); // #note@16: passing argument to parameter here // #note@16: passing argument to parameter here // #note@16: passing argument to parameter here
extern void s(struct Foo); // #note@15: passing argument to parameter here
extern void var(int, ...);

void foo(void) {
    b(1);
    b(1.f);
    b((int *)1);
    b((void)1); // #error@7: passing 'void' to parameter of incompatible type '_Bool'
    i(1);
    i(1.f);
    i((int *)1); // #warning@7: implicit pointer to integer conversion from 'int *' to 'int' [-Wint-conversion]
    f(1);
    f(2.);
    f((int *)1); // #error@7: passing 'int *' to parameter of incompatible type 'float'
    ip(1); // #warning@8: implicit integer to pointer conversion from 'int' to 'int *' [-Wint-conversion]
    ip((int *)1);
    ip(2.f); // #error@8: passing 'float' to parameter of incompatible type 'int *'
    struct Foo a;
    s(a);
    s(1); // #error@7: passing 'int' to parameter of incompatible type 'struct Foo'
    var(1, 1.f, (char)1, a);
}

enum E;
void bar(enum E e) { // #error@17: parameter has incomplete type 'enum E'
    baz(e); // #error@5: call to undeclared function 'baz'; ISO C99 and later do not support implicit function declarations [-Wimplicit-function-declaration]
}

void void_star_param(void *p) {} // #note@28: passing argument to parameter here // #note@28: passing argument to parameter here // #note@28: passing argument to parameter here

void call_void_star(void) {
    void_star_param(0);
    void_star_param(4.0); // #error@21: passing 'double' to parameter of incompatible type 'void *'
    struct S {
        int x;
    } s;
    void_star_param(s); // #error@21: passing 'struct S' to parameter of incompatible type 'void *'
    void_star_param(&s);
    void_star_param((_Complex int)42); // #error@21: passing '_Complex int' to parameter of incompatible type 'void *'
    long x;
    ip(&x); // #warning@8: passing 'long *' to parameter of incompatible type 'int *' [-Wincompatible-pointer-types]
}

void signed_int(int *p) {} // #note@22: passing argument to parameter here

void call_with_unsigned(void) {
    unsigned int x = 0;
    signed_int(&x); // #warning@16: passing 'unsigned int *' to parameter of incompatible type 'int *' converts between pointers to integer types with different sign [-Wpointer-sign]
}

void func_no_proto();
void pass_args_to_no_proto(int a) {
    func_no_proto(a); // #warning@19: passing arguments to a function without a prototype is deprecated in all versions of C and is not supported in C23 [-Wdeprecated-non-prototype]
}

