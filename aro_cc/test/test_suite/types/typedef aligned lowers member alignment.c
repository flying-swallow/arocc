// `aligned` on a typedef may lower alignment (GCC/Clang); a record member of that
// typedef type uses it. sysprof-6 static-asserts these sizes.
typedef struct { long long a; int b; } F __attribute__((aligned(1)));
typedef struct { F f; unsigned n; unsigned char d[0]; } J __attribute__((aligned(1)));
struct Plain { long long a; int b; };
struct K { char c; F f; };
struct L { char c; struct Plain p; };
_Static_assert(sizeof(F) == 16, "F keeps its natural size");
_Static_assert(_Alignof(F) == 1, "F alignment lowered");
_Static_assert(sizeof(J) == 20, "J packs F without padding to 8");
_Static_assert(sizeof(struct K) == 17, "member of lowered typedef at offset 1");
_Static_assert(sizeof(struct L) == 24, "plain struct member keeps alignment 8");
