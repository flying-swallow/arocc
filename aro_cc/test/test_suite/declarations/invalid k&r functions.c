// #opt: -std=c17
int invalid1() // #error@14: expected function body after function declaration
int invalid2(x) // #warning@5: a function definition without a prototype is deprecated in all versions of C and is not supported in C23 [-Wdeprecated-non-prototype] // #error@14: parameter 'x' was not declared, defaults to 'int'; ISO C99 and later do not support implicit int [-Wimplicit-int] // #error@16: expected function body after function declaration

