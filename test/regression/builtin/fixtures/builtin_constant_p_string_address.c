// Source-derived from test/cases/builtin_constant_p.c.
/** manifest:
syntax
*/
int global;

_Static_assert(!__builtin_constant_p(global), "global object is not an integer constant");
_Static_assert(__builtin_constant_p(&"bar"), "string literal address is constant");
