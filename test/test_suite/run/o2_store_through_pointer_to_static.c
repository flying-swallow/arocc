// #kind: run
// #exit: 0
// #opt: -O2
// csmith seed 320, reduced. -O0/-O1 exit 0; -O2 exits 7: the store through p is
// dropped (or g's initializer is propagated past it). Expected: exit 0.
static int g = 7;
static int f(void) { int *p = &g; *p = 0; return g; }
int main(void) { f(); return g; }
