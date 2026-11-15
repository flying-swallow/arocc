struct Foo {
    int a;
} a;

void foo(void) {
    int a;
    a->a; // #error@8: member reference base type 'int' is not a structure or union
}
void bar(void) {
    a->a; // #error@8: member reference type 'struct Foo' is not a pointer; did you mean to use '.'?
}
void baz(void) {
    a->b; // #error@8: member reference type 'struct Foo' is not a pointer; did you mean to use '.'? // #error@8: no member named 'b' in 'struct Foo'
}
void quux(struct Foo *a) {
    a.b; // #error@7: member reference type 'struct Foo *' is a pointer; did you mean to use '->'? // #error@7: no member named 'b' in 'struct Foo'
    int b, *c;
    b.a; // #error@7: member reference base type 'int' is not a structure or union
    c.a; // #error@7: member reference base type 'int *' is not a structure or union
    c->a; // #error@8: member reference base type 'int *' is not a structure or union
}

char *quuux(char *arg) {
    return arg + a.a;
}

struct Bar {
    struct {
        union {
            int x;
        };
    };
} *b;

int f1(void) {
    return b->x;
}

struct Foo c[1];
int f2(void) {
    return c->a;
}

void f3(void) {
    (void)&((struct Foo *)(0x100000u))->a;
    (void)&((struct Foo **)0x100000u)[0];
    (void)&((struct Foo (*)[1])0x100000u)[0]->a;
    (void)&((struct Foo **)(int)(_Complex int)1)[0];
    (void)&((struct Foo **)(_Bool)1)[0];
}

