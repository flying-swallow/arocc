// #opt: -std=gnu89 -Wno-deprecated-non-prototype
/* Zig Parser.decl: a file-scope declaration with no declaration specifiers is
   implicit int (gcc.c-torture/compile/xfoo.c, xlop.c, zero-strct-1.c). */
foo (a)
{
  return a + 1;
}
*p; // #warning@1: data definition has no type or storage class
(paren)(void) { return 1; }
bar (); // #warning@1: data definition has no type or storage class
count = 3; // #warning@1: data definition has no type or storage class

/* A failure inside `__typeof (...)` resumes after the whole declaration, not
   at the identifier inside the parentheses (gcc.dg/pr20368-1.c). */
extern __typeof (undeclared) g, h; // #error@18: use of undeclared identifier 'undeclared'
int after;
