// A `(` that starts a parenthesized declarator may be followed by `[` (an array
// abstract declarator) or by GNU attributes (c-testsuite 00209, 00210); a
// parameter list that starts with an attribute is still a function suffix.
int f8(int ([4]), int);
int f8(int *p, int i);
int f4(int (*[4])(int), int);
typedef int (*fp)(void);
void *vp;
int call(void) { return ((int (__attribute__((__noinline__)) *)(void))vp)(); }
void params(__attribute__((unused)) int x);
typedef int T;
void typedef_param(int (__attribute__((unused)) T));
_Static_assert(sizeof(int ([4])) == 4 * sizeof(int), "array type name");
