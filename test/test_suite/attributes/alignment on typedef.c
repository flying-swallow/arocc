// #skip: diagnostics differ (aro_c3 gap)
// #opt: -target x86_64-linux-gnu
__attribute__((aligned(2))) typedef struct {
  int a;
} X;

typedef struct {
  int a;
} __attribute__((aligned(2))) Y;

_Static_assert(sizeof(X) == 4, "");
_Static_assert(_Alignof(X) == 2, "");

_Static_assert(sizeof(Y) == 4, "");
_Static_assert(_Alignof(Y) == 4, "");

