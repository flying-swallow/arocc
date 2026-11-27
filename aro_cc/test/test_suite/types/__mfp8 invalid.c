// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c23 --target=aarch64-linux-gnu
void foo(__mfp8 a, __mfp8 b) {
    a + b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    -a; // #error@5: invalid argument type '__mfp8' to unary expression
    ++a; // #error@5: invalid argument type '__mfp8' to unary expression
    a < b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    if (a) {} // #error@9: statement requires expression with scalar type ('__mfp8' invalid)
    int i = a; // #error@13: initializing 'int' from incompatible type '__mfp8'
    float f = a; // #error@15: initializing 'float' from incompatible type '__mfp8'
    __mfp8 x = 0; // #error@16: initializing '__mfp8' from incompatible type 'int'
    (__mfp8){0}; // #error@14: initializing '__mfp8' from incompatible type 'int'
    a += b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    a -= b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    a *= b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    a /= b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    a %= b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    a &= b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    a |= b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    a ^= b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    a <<= 1; // #error@7: invalid operands to binary expression ('__mfp8' and 'int')
    a >>= 1; // #error@7: invalid operands to binary expression ('__mfp8' and 'int')
    (int)a; // #error@10: operand of type '__mfp8' where arithmetic or pointer type is required
    (float)a; // #error@12: operand of type '__mfp8' where arithmetic or pointer type is required
    (__mfp8)0; // #error@5: cannot cast to non arithmetic or pointer type '__mfp8'
    (__mfp8)1.0f; // #error@5: cannot cast to non arithmetic or pointer type '__mfp8'
    const __mfp8 c = a; // #note@18: variable 'c' declared const here
    c = b; // #error@7: cannot assign to variable 'c' with const-qualified type 'const __mfp8'
    while (a) {} // #error@12: statement requires expression with scalar type ('__mfp8' invalid)
    for (; a;) {} // #error@10: statement requires expression with scalar type ('__mfp8' invalid)
    do {} while (a); // #error@18: statement requires expression with scalar type ('__mfp8' invalid)
    a && b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    a || b; // #error@7: invalid operands to binary expression ('__mfp8' and '__mfp8')
    !a; // #error@5: invalid argument type '__mfp8' to unary expression
    switch (a) {} // #error@13: statement requires expression with integer type ('__mfp8' invalid)
    __mfp8 bad_arr[2] = { 0 }; // #error@27: initializing '__mfp8' from incompatible type 'int'
    struct bad_holder {
        __mfp8 value;
    } bad_holder = { 0 }; // #error@22: initializing '__mfp8' from incompatible type 'int'
    __auto_type auto_int = 0;
    __auto_type auto_mfp8 = a;
    auto c23_auto_int = 0;
    auto c23_auto_mfp8 = a;
    auto_mfp8 = auto_int; // #error@15: assignment to '__mfp8' from incompatible type 'int'
    c23_auto_mfp8 = c23_auto_int; // #error@19: assignment to '__mfp8' from incompatible type 'int'
    void take_mfp8(__mfp8); // #note@20: passing argument to parameter here // #note@20: passing argument to parameter here
    void take_int(int); // #note@19: passing argument to parameter here
    take_mfp8(0); // #error@15: passing 'int' to parameter of incompatible type '__mfp8'
    take_mfp8(1.0f); // #error@15: passing 'float' to parameter of incompatible type '__mfp8'
    take_int(a); // #error@14: passing '__mfp8' to parameter of incompatible type 'int'
    _Complex __mfp8 complex_mfp8; // #warning@5: plain '_Complex' requires a type specifier; assuming '_Complex double' // #error@21: expected ';', found 'an identifier'
}


