// #kind: run
// #exit: 0
// __alignof__ of an expression sees the named member's or variable's own
// aligned/packed attributes, as GCC and Clang do.
struct S { char c; int i __attribute__((aligned(8))); short h; } t;
struct A { char c; int i __attribute__((packed)); } a;
struct __attribute__((packed)) B { char c; int i; } b;
struct C { char c; int i __attribute__((packed, aligned(2))); } c;
_Alignas(32) static int v;
_Static_assert(__alignof__(t.i) == 8, "aligned member");
_Static_assert(__alignof__((t.h)) == 2, "plain member");
_Static_assert(__alignof__(a.i) == 1, "packed member");
_Static_assert(__alignof__(b.i) == 1, "member of packed record");
_Static_assert(__alignof__(c.i) == 2, "packed and aligned member");
_Static_assert(__alignof__(v) == 32, "aligned variable");
int main(void) { struct S *p = &t; return __alignof__(p->i) == 8 ? 0 : 1; }
