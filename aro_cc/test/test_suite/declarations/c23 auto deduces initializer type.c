// #opt: -std=c23 -target x86_64-linux
#define IS(x, T) _Generic(&(x), T *: 1, default: 0)
auto inferred = 42;

_Static_assert(IS(inferred, int), "");
