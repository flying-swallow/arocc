void foo(int x) {
    _Static_assert(x, "not allowed"); // #error@20: static assertion expression is not an integral constant expression
    _Static_assert(1); // #warning@5: '_Static_assert' with no message is a C23 extension [-Wc23-extensions]
    _Static_assert(0); // #warning@5: '_Static_assert' with no message is a C23 extension [-Wc23-extensions] // #error@20: static assertion failed due to requirement '0'
}

void bar(void) {
    _Static_assert(1, "ok", "not ok"); // #error@27: expected ')', found ',' // #note@19: to match this '('
}

_Static_assert(1 == 0, "They are not equal!"); // #error@16: static assertion failed due to requirement '1 == 0': They are not equal!
_Static_assert(sizeof(int) == 3, ""); // #error@16: static assertion failed due to requirement 'sizeof(int) == 3' // #note@28: expression evaluates to '4 == 3'

