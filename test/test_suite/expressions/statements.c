// #skip: diagnostics differ (aro_cc gap)
// #opt: -std=c17
void foo(void) {
    if ((char)1); // #warning@17: if statement has empty body [-Wempty-body] // #note@17: put the semicolon on a separate line to silence this warning
    if ((void)1); // #error@9: statement requires expression with scalar type ('void' invalid) // #warning@17: if statement has empty body [-Wempty-body] // #note@17: put the semicolon on a separate line to silence this warning
    switch (1.f); // #error@13: statement requires expression with integer type ('float' invalid)
    for (foo;(void)2;); // #warning@10: expression result unused [-Wunused-value] // #error@10: statement requires expression with scalar type ('void' invalid)
    int x;
    switch (x) case x: return; // #error@21: case value must be an integer constant expression
    switch (x) {
        case 1:
            x = 1;
            break;
        default:
            break;
    }
    enum FOO {BAR, BAZ} y = BAR;
    if (y) return;
    if (!BAZ) return;
    int a, b;
    for (a=1,b=1;;);
    for (int i = 2, b = 4; i + 2; i = 2);
}

void bar(int arg) {
    if (arg) goto next;
    if (arg == 2) goto next;
    if (arg == 3) goto next;
    next: return;
}

#pragma GCC diagnostic warning "-Wc2y-extensions"
void baz(int arg) {
    switch (arg) {
        case 1 ... 3: // #warning@16: case ranges are a C2y extension [-Wc2y-extensions] // #note@14: previous case defined here
        case 2: // #error@14: duplicate case value '2'
            break;
        default:
            return;
    }
    if (1)
        ;
}

