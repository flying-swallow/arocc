// #todo: TODO no missing type error after missing semicolon/comma
typedef long foo; // #note@14: previous definition is here
typedef unsigned foo bar; // TODO no missing type error // #error@18: typedef redefinition with different types ('unsigned int' vs 'long') // #error@22: expected ';', found 'an identifier' // #error@22: type specifier missing, defaults to 'int'; ISO C99 and later do not support implicit int [-Wimplicit-int]

typedef double baz; // #note@16: previous definition is here
typedef long baz; // #error@14: typedef redefinition with different types ('long' vs 'double')

