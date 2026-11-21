// #opt: -std=c17 -target x86_64-linux
// GNU attributes and _Atomic after `*` must not hide the parameter name from
// the named/abstract lookahead (glibc `char *__attribute__((...)) p`).
void f1(char *__attribute__((unused)) p) { (void)p; }
void f2(char *const __attribute__((unused)) *_Atomic p) { (void)p; }
void f3(int (*__attribute__((unused)) fp)(int)) { (void)fp; }
// Abstract forms: the attribute argument is not a declarator name.
void f4(char *__attribute__((unused)));
void f5(int (*__attribute__((unused)))(int));
// Named and unnamed parenthesized/pointer shapes share the optional-name mode.
void f6(int (*)(int), int (*fp)(int), char *(p), int (x)[3], int *[2], int (int));
int g(a) int a; { return a; } // #warning@5: a function definition without a prototype is deprecated
