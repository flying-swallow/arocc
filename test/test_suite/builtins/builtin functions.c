// #opt: --target=powerpc-freestanding-none
int foo(void) {
    char c[] = "hello";
    return strlen(c); // #error@12: implicitly declaring library function 'strlen' [-Wimplicit-function-declaration] // #note@12: include the header <string.h> or explicitly provide a declaration for 'strlen'
}

void bar(int x) {
    __builtin_ppc_trap(x);
}

void ns_constant_string(void) {
    const __NSConstantString *ns_str = __builtin___NSStringMakeConstantString("Hello, world!");
    (void)ns_str;
}

