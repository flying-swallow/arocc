// #opt: -std=c17
static x = 5; // #error@8: type specifier missing, defaults to 'int'; ISO C99 and later do not support implicit int [-Wimplicit-int]

