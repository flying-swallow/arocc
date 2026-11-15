// #skip: diagnostics differ (aro_c3 gap)
struct Foo {
    Bar bar; // #error@5: unknown type name 'Bar'
};

struct Baz {
    struct Foo foo;
};

