// #opt: -std=c17
foo(void) { return 1; } // #error@1: type specifier missing, defaults to 'int'; ISO C99 and later do not support implicit int [-Wimplicit-int]
unknown_t x; // #error@1: unknown type name 'unknown_t'
