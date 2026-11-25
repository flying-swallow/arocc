// #opt: -std=c23 -target x86_64-linux
#define IS(x, T) _Generic(&(x), T *: 1, default: 0)
const volatile int source_cv = 1; typeof_unqual(source_cv) plain_copy;
typeof_unqual(const volatile int) plain_type; const typeof_unqual(source_cv) const_copy;
typeof_unqual(const int *) pointer_copy; typeof_unqual(typeof(const int)) nested_type;

_Static_assert(IS(source_cv, const volatile int), "");
_Static_assert(IS(plain_copy, int), "");
_Static_assert(IS(plain_type, int), "");
_Static_assert(IS(const_copy, const int), "");
_Static_assert(IS(pointer_copy, const int *), "");
_Static_assert(IS(nested_type, int), "");

const unsigned _BitInt(12) width_source = 1; typeof_unqual(width_source) width_copy = 2;
_Static_assert(IS(width_source, const unsigned _BitInt(12)), "");
_Static_assert(IS(width_copy, unsigned _BitInt(12)), "");
