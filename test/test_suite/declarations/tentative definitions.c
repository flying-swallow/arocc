// #skip: diagnostics differ (aro_cc gap)
struct Tentative; // #note@8: forward declaration of 'struct Tentative'
struct Tentative t1, t2; // #error@18: tentative definition has type 'struct Tentative' that is never completed

void foo(void) {
    struct Tentative { // does not complete tentative definition in outer scope
        int x;
    };

    struct S1 s1; // tentative definition not allowed in function // #error@15: variable has incomplete type 'struct S1'
    struct S1 {
        int a,b,c,d;
    };
}

enum E e; // #error@8: tentative definition has type 'enum E' that is never completed // #note@6: forward declaration of 'enum E'

union __attribute__((aligned(32))) U; // #note@36: forward declaration of 'union U'
union __attribute__((aligned(64))) U u; // #error@38: tentative definition has type 'union U' that is never completed

struct S1 s1;
struct S2;
struct S2 s2;

struct S1 {
    int x;
};

struct S2 {
    int x;
    int y;
};

_Static_assert(sizeof(s1) == sizeof(struct S1), "");
_Static_assert(sizeof(s2) == sizeof(struct S2), "");

struct A {
    struct B b; // #error@14: field has incomplete type 'struct B'
};
struct B {
    int x;
};

extern struct Tentative tentative_extern;

