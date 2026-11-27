void foo(void) {
    int x = 10;
    (void)(x/0); // #warning@13: division by zero is undefined [-Wdivision-by-zero]
    (void)(x%0); // #warning@13: remainder by zero is undefined [-Wdivision-by-zero]
    x /= 0; // #warning@7: division by zero is undefined [-Wdivision-by-zero]
    x %= 0; // #warning@7: remainder by zero is undefined [-Wdivision-by-zero]
    (void)(0/0); // #warning@13: division by zero is undefined [-Wdivision-by-zero]
    (void)(1%0); // #warning@13: remainder by zero is undefined [-Wdivision-by-zero]
    _Static_assert(1/0, "unavailable"); // #warning@21: division by zero is undefined [-Wdivision-by-zero] // #error@20: static assertion expression is not an integral constant expression
    float f = 0.0f / 0.0f;
    f /= 0.0f;
    x = 1 / 2.0f;
}

