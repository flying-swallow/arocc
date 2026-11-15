// #skip: diagnostics differ (aro_c3 gap)
struct __attribute__((packed)) Foo {
    int x;
};
struct Foo foo;
int *p = &foo.x; // #warning@10: taking address of packed member 'x' of class or structure 'Foo' may result in an unaligned pointer value [-Waddress-of-packed-member]


