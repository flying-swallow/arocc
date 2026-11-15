struct S {
    int x;
};

void foo(void) {
    struct S s;
    s.y; // #error@7: no member named 'y' in 'struct S'
}

_Static_assert(u"A"); // #warning@1: '_Static_assert' with no message is a C23 extension [-Wc23-extensions] // #error@16: static assertion expression is not an integral constant expression

