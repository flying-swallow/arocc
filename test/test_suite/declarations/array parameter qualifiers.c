// C99 6.7.6.2/6.7.6.3p7: qualifiers and `static` inside a parameter's array
// brackets qualify the pointer it decays to (glibc `regex.h` `[__restrict_arr]`).
void f(int n, char *const argv[__restrict]);
void g(int a[const 5]);
void g(int *const a);
void h(int b[restrict static 4]);
void h(int *restrict b);
void k(int c[static const 2]);
void k(int *const c);
void s(int n, int d[const *]);
void m(int e[const 5]) { e = 0; } // #error@28: expression is not assignable
int bad_quals[const 3]; // #error@15: type qualifier in non parameter array type
int bad_static[static 3]; // #error@16: 'static' used outside of function parameters
int vla(int *p) { int v[*p]; return sizeof v; }
