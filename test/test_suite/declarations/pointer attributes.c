/* GNU attributes among pointer qualifiers (Zig typeQual allow_attr; glibc
   `char *__attribute__ ((__nothrow__)) strcpy (...)`, gcc.dg/Wobjsize-1.h). */
char *__attribute__((unused)) p;
char *const __attribute__((unused)) volatile q;
extern __inline __attribute__((__always_inline__)) char *
__attribute__((__warn_unused_result__)) copy(char *d) { return d; }
