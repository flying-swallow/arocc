// #opt: -target x86_64-linux
struct Outer { char a; struct __attribute__((aligned(8))) { int b; }; };
_Static_assert(__builtin_offsetof(struct Outer, b) == 8, "aligned anonymous member starts at offset 64 bits");
_Static_assert(_Alignof(struct Outer) == 8, "");
_Static_assert(sizeof(struct Outer) == 16, "");
