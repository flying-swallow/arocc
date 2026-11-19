// #opt: -std=c90 -pedantic-errors
/* C90 6.1.3.2: an unsuffixed decimal tries int, long, unsigned long; being
   unsigned is standard there, so it is a plain warning, not a pedantic error
   (gcc.dg/c90-intconst-1.c). */
unsigned long big = 9223372036854775808; // #warning@21: this decimal constant is unsigned only in ISO C90
unsigned long big_l = 9223372036854775808l; // #warning@23: this decimal constant is unsigned only in ISO C90
long fits = 9223372036854775807;

/* C 6.5.15p6: a null pointer constant arm takes the other arm's type, including
   `(void *)E` for a folded constant E inside the unevaluated __typeof__ operand. */
void null_pointer_constants(void) {
    int **a;
    __typeof__(0 ? (int *)0 : (void *)0) *p0 = 0;
    __typeof__(0 ? (int *)0 : (void *)(!1)) *p1 = 0;
    __typeof__(1 ? (int *)0 : (void *)(1 - 1)) *p2 = 0;
    __typeof__(0 ? (int *)0 : (void *)(2 - 1)) *v = 0;
    a = p0;
    a = p1;
    a = p2;
    a = v; // #warning@7: incompatible pointer types assigning to 'int **' from incompatible type 'typeof(void *) *' (aka 'void **') [-Wincompatible-pointer-types]
}
