// #skip: diagnostics differ (aro_c3 gap)
// #todo: TODO visibility warning for struct declared in function parameter
struct S;
union U;
void foo(struct S *s) {
    s->a; // #error@5: dereferencing pointer to incomplete type 'struct S'
    (void)*s; // #error@11: dereferencing pointer to incomplete type 'struct S'
}
void bar(union U *u) {
    u->a; // #error@5: dereferencing pointer to incomplete type 'union U'
    (void)*u; // #error@11: dereferencing pointer to incomplete type 'union U'
}
void baz(void) {
    enum E e; // #error@12: variable has incomplete type 'enum E'
    if (e) {}
}

struct node {
    struct S s; // #error@14: field has incomplete type 'struct S'
};

void contains_incomplete(void) {
    struct node n = {0}; // #error@17: variable has incomplete type 'struct node'
}

struct self_referential {
    struct self_referential s; // #error@29: field has incomplete type 'struct self_referential'
};

void contains_self_referential(void) {
    struct self_referential s = {0}; // #error@29: variable has incomplete type 'struct self_referential'
}

void switch_with_incomplete(void) {
    struct node n; // #error@17: variable has incomplete type 'struct node'
    switch (n) {
        case 1: break;
    }
}

void incomplete_enum_float(void) {
    enum E e; // #error@12: variable has incomplete type 'enum E'
    e = 1.0f;
}

void incomplete_unspecified_variable_len_array(struct S b[1][*]); // #error@58: array has incomplete element type 'struct S'

void f1(struct Foo *a) { } /* should produce `declaration of 'struct Foo' will not be visible outside of this function [-Wvisibility]` instead of tentative definition error */ // #note@16: forward declaration of 'struct Foo'

struct Foo f; // #error@12: tentative definition has type 'struct Foo' that is never completed // #error@12: tentative definition has type 'struct Foo' that is never completed // #note@8: forward declaration of 'struct Foo'

void member_access_incomplete_struct(struct Foo f) { // #error@49: parameter has incomplete type 'struct Foo'
    f.a;
}

