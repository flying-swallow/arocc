// #kind: run
// #exit: 0
// GNU `aligned` on a function: `__alignof__` reports it and the code is
// placed at that alignment (gcc.c-torture/execute/align-3.c).
void func(void) __attribute__((aligned(256)));
void func(void) {}
__attribute__((aligned(64))) int other(int x) { return x + 1; }
int plain(void) { return 0; }

int main(void)
{
	if (__alignof__(func) != 256) return 1;
	if (__alignof__(other) != 64) return 2;
	if ((unsigned long)&func % 256 != 0) return 3;
	if ((unsigned long)&other % 64 != 0) return 4;
	if (other(1) != 2 || plain() != 0) return 5;
	return 0;
}
