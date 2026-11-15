// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c23 --emulate=clang -pedantic
void foo(int x, float y) {
    _Static_assert(__imag(42) == 0);
    _Static_assert(__imag(42.0) == 0.0);
    _Static_assert(__imag(x) == 0); // #error@20: static assertion expression is not an integral constant expression
    _Static_assert(__imag(y) == 0); // #error@20: static assertion expression is not an integral constant expression

    _Complex double z = (_Complex double){1.0, 2.0}; // #warning@42: complex initialization specifying real and imaginary components is an extension [-Wcomplex-component-init]
    z++; // #warning@6: ISO C does not support '++'/'--' on complex type '_Complex double' [-Wpedantic]

    z = __builtin_complex(2.0, 3); // #error@32: argument type 'int' is not a real floating point type
    z = __builtin_complex(2.0, 3.0f); // #error@32: arguments are of different types ('double' vs 'float')
    z = __builtin_complex(2.0, 3.0);
    z = ~z; // #warning@9: ISO C does not support '~' for complex conjugation of '_Complex double' [-Wpedantic]
}

