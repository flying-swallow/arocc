// #opt: -std=c23 -target x86_64-linux
#define IS(x, T) _Generic(&(x), T *: 1, default: 0)
_BitInt(2) default_min; signed _BitInt(8) explicit_signed; _BitInt(9) signed signed_after_width;
unsigned _BitInt(1) unsigned_min; _BitInt(16) unsigned unsigned_after_width;
unsigned _BitInt(65535) unsigned_max; _BitInt(65535) signed_max; _BitInt(4 * 2) expression_width;

_Static_assert(IS(default_min, signed _BitInt(2)), "");
_Static_assert(IS(explicit_signed, signed _BitInt(8)), "");
_Static_assert(IS(signed_after_width, signed _BitInt(9)), "");
_Static_assert(IS(unsigned_min, unsigned _BitInt(1)), "");
_Static_assert(IS(unsigned_after_width, unsigned _BitInt(16)), "");
_Static_assert(IS(unsigned_max, unsigned _BitInt(65535)), "");
_Static_assert(IS(signed_max, signed _BitInt(65535)), "");
_Static_assert(IS(expression_width, signed _BitInt(8)), "");
