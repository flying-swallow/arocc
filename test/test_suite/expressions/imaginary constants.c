#pragma GCC diagnostic push
#pragma GCC diagnostic warning "-Wgnu-imaginary-constant"

void foo(void) {
    _Complex double cd = 1.0 + 2.0i; // #warning@32: imaginary constants are a GNU extension [-Wgnu-imaginary-constant]
#pragma GCC diagnostic pop
    _Complex float cf = 1.0f + 2.0if;

    _Complex long double cld;
    cld = 1.0l + 2.0il;

#pragma GCC diagnostic warning "-Wgnu-complex-integer"
    int _Complex ci = 1i; // #warning@9: complex integer types are a GNU extension [-Wgnu-complex-integer]
#pragma GCC diagnostic ignored "-Wgnu-complex-integer"
    _Complex unsigned long cl = 1uli; 
}

#if 1.0i // #error@5: floating point literal in preprocessor expression
#endif

