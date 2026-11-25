// #opt: -target x86_64-linux
// __auto_type publishes the deduced type before a later initializer looks the variable up.
#define IS(x, T) _Generic(&(x), T *: 1, default: 0)
__auto_type source = (long)1; __auto_type copy = source;

_Static_assert(IS(source, long), "");
_Static_assert(IS(copy, long), "");
