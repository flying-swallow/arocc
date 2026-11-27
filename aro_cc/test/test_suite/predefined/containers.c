// #skip: diagnostics differ (aro_cc gap)
int IntTest;

enum EnumTest
{
    Begin,
    End,
};

enum Foo { // #note@6: previous definition is here
    A = 13,
    B = A + 4,
    C,
};

struct Foo a; // #error@8: use of 'Foo' with tag type that does not match previous definition // #error@12: tentative definition has type 'struct Foo' that is never completed // #note@8: forward declaration of 'struct Foo'

struct StructTest{
    union Bar {
        int a;
    }; // #warning@6: declaration does not declare anything [-Wmissing-declaration]
    int MemberTest, :0, , a: 2; // #error@25: expected member name after declarator
    _Static_assert(sizeof(struct StructTest), "foo"); // #error@20: invalid application of 'sizeof' to an incomplete type 'struct StructTest'
};

void foo(void) { // #note@6: previous definition is here
    union StructTest {
        int b;
    };
}

void bar(void) {
    struct Foo;
    {
        struct Foo {
            int a;
        };
    }
    sizeof(struct Foo); // #error@5: invalid application of 'sizeof' to an incomplete type 'struct Foo'
    StructTest a; // #error@5: must use 'struct' tag to refer to type 'StructTest'
}

enum {
    D,
};

struct { // #warning@1: declaration does not declare anything [-Wmissing-declaration]
    struct {
        int a;
    };
};

struct StructWithEnum{
    enum {
        E = 5.f, // #error@13: expression is not an integer constant expression
    };
};

enum {
    F = IntTest, // #error@9: enum value must be an integer constant expression
};

union SomeUnion {
    int a;
};
typedef union SomeUnion SomeUnion;

typedef struct forward_struct forward_struct;
struct forward_struct {
    forward_struct *a;
};

typedef enum forward_enum forward_enum;
enum forward_enum {
    forward_enum_a = sizeof(forward_enum *),
};

void baz(void) {
    struct a {int a;} a;
    (void) a.a;
}

void foo(void);
struct foo { int a; };
void foo(void) { // #error@6: redefinition of 'foo'
    foo();
}

int len;
struct S1 {
    void a(); // #error@10: field declared as a function
    void b; // #error@10: field has incomplete type 'void'
    int c[len]; // #error@9: variable length array fields extension is not supported
};

struct S2 {
    int a[]; // #error@9: flexible array member in otherwise empty struct
};

struct S3 {
    int a[]; // #error@9: flexible array member is not at the end of struct
    int b;
};

struct S4 {
    int a[]; // #error@9: flexible array member is not at the end of struct
    int b[]; // #error@9: flexible array member is not at the end of struct
    int c;
};

struct S5 {
    int a;
    int b[];
};

union U {
    int a[]; // #error@9: flexible array member in union is not allowed
};

struct S {
    enum EnumTest1:2; // #error@19: field has incomplete type 'enum EnumTest1'
};

struct A {
    struct B {
        int a;
    } a;
} a1;
struct B b1;

void qux(void) {
    enum A; // #note@10: previous definition is here
    struct A e; // #error@12: use of 'A' with tag type that does not match previous definition // #error@14: variable has incomplete type 'struct A'
}
struct A;
struct A a2;

struct NoTrailingSemicolon {
    int a;
    int b
}; // #warning@1: expected ';' at end of declaration list

