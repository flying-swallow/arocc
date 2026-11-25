// GCC: in `enum E __attribute__((aligned(8))) c;` (no body after the tag name) the
// attribute belongs to the declared member, not to `enum E` itself. Applying it to
// the tag made every later `enum E[n]` an over-aligned array (gcc compat
// struct-layout-1 tests).
enum E { a };
struct R { char x; enum E __attribute__((aligned(8))) c; };
_Static_assert(_Alignof(enum E) == 4, "enum E unchanged");
_Static_assert(__builtin_offsetof(struct R, c) == 8, "member aligned");
enum E arr[3];
