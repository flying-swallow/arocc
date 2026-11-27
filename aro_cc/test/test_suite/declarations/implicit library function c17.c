// #opt: -std=c17
int f(void) { return strlen("a"); } // #error@22: implicitly declaring library function 'strlen' [-Wimplicit-function-declaration] // #note@22: include the header <string.h> or explicitly provide a declaration for 'strlen'
