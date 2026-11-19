// #kind: syntax
// Reduced from GCC testsuite cases that used to crash aro_c3.
#include <stdarg.h>

int label_diff(void)
{
    void *x = &&L2;
    if (&&L3 - &&L1 > 1) return 2;
L1: return 1;
L2: return 0;
L3:;
    return (int)(long)x;
}

int va_compare(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    int ok = va_arg(ap, int) != 101;
    va_end(ap);
    return ok;
}

int cast_incomplete(int x)
{
    return x != (int)sizeof((enum T)0x1234); // #error: cast to incomplete type 'enum T'
}

struct with_incomplete_bitfield {
    enum tree_code code : 8; // #error: field has incomplete type 'enum tree_code'
}; // recovery skips the rest of the failed struct: no cascade error here

void takes_incomplete(enum E e) {} // #error: parameter has incomplete type 'enum E'
void call_incomplete(void) { takes_incomplete(0); }

typedef const int CI;
_Atomic CI atomic_of_qualified;
_Atomic(CI) atomic_specifier_qualified; // #error: _Atomic cannot be applied to qualified type

void atomic_pointer(void)
{
    int a[2];
    int *_Atomic ap;
    int *p = a;
    ap = p;
    ap++;
    ap += 1;
}

void error_attr(void) __attribute__((__error__("")));

_Complex char complex_compare(_Complex char a) { return a != 1 + 2i; }
