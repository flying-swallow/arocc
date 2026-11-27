// #skip: block-scope `int x[[deprecated]];` misparses as a subscript (aro_cc gap); deprecated uses otherwise match
// #opt: -std=c23 -Wno-unused-value
void foo(__attribute__((deprecated)) int arg, int arg2 __attribute__((deprecated))) { // #note@25: 'arg' has been explicitly marked deprecated here // #note@71: 'arg2' has been explicitly marked deprecated here
    __attribute__((deprecated)) int foo = 1; // #note@20: 'foo' has been explicitly marked deprecated here
    int __attribute__((deprecated)) bar = 2; // #note@24: 'bar' has been explicitly marked deprecated here
    int baz __attribute__((deprecated)) = 3; // #note@28: 'baz' has been explicitly marked deprecated here

    foo; // #warning@5: 'foo' is deprecated [-Wdeprecated-declarations]
    bar; // #warning@5: 'bar' is deprecated [-Wdeprecated-declarations]
    baz; // #warning@5: 'baz' is deprecated [-Wdeprecated-declarations]
    arg; // #warning@5: 'arg' is deprecated [-Wdeprecated-declarations]
    arg2; // #warning@5: 'arg2' is deprecated [-Wdeprecated-declarations]
}

void bar(int __attribute__((deprecated)) arg __attribute__((aligned))) { // #note@29: 'arg' has been explicitly marked deprecated here
    (void) arg; // #warning@12: 'arg' is deprecated [-Wdeprecated-declarations]
}

void baz(void) {
    int x[[deprecated]]; // #note@12: 'x' has been explicitly marked deprecated here
    x = 5; // #warning@5: 'x' is deprecated [-Wdeprecated-declarations]
}

struct S {
    int __attribute__((deprecated("foo", "bar"), packed)) p; // #note@24: 'p' has been explicitly marked deprecated here
};

int deprecated_field(struct S s) {
    (void)__builtin_offsetof(struct S, p);
    return s.p; // #warning@14: 'p' is deprecated: foo [-Wdeprecated-declarations] // #note@14: use 'bar' instead
}

