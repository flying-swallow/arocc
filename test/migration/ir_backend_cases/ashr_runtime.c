// expect 7
int ashr(int a, int n) { return a >> n; }
unsigned lshr(unsigned a, int n) { return a >> n; }
int main(void) { return (ashr(-8, 1) == -4) + (lshr(0x80000000u, 31) == 1u) * 2 + (ashr(-1, 5) == -1) * 4; }
