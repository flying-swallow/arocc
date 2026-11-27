// #opt: -std=c99 -target x86_64-linux
void partial(kept, omitted) long kept; { } // #warning@6: a function definition without a prototype is deprecated in all versions of C and is not supported in C23 // #error@20: parameter 'omitted' was not declared, defaults to 'int'; ISO C99 and later do not support implicit int
