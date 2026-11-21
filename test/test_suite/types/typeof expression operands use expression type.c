// #opt: -std=c23 -target x86_64-linux
#define IS(x, T) _Generic(&(x), T *: 1, default: 0)
const long source_long = 3; int base = 1;
typeof(base) copy_base; typeof(source_long) copy_long; typeof(1L) literal_long;
typeof((unsigned char)1) cast_uchar; const typeof(base) const_copy;

_Static_assert(IS(copy_base, int), "");
_Static_assert(IS(copy_long, const long), "");
_Static_assert(IS(literal_long, long), "");
_Static_assert(IS(cast_uchar, unsigned char), "");
_Static_assert(IS(const_copy, const int), "");
