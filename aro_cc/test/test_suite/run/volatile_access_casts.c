// #kind: run
// #exit: 0
/* Volatile-qualified accesses through casts of ordinary objects stay real
   memory operations at every optimization level. */
static void poke(volatile int *p) { *p = 1; *p = 2; }
int global_value = 7;
static int read_cast(int *q) { return *(volatile int *)q; }
int main(void)
{
	int x = 0;
	*(volatile int *)&x = 5;
	if (*(volatile int *)&x != 5) return 1;
	poke((volatile int *)&x);
	if (x != 2) return 2;
	(*(volatile int *)&x)++;
	if (x != 3) return 3;
	*(volatile int *)&global_value += 1;
	if (read_cast(&global_value) != 8) return 4;
	struct { volatile unsigned bits : 3; unsigned other : 5; } s = { 0, 0 };
	s.bits = 5;
	if (s.bits != 5) return 5;
	return 0;
}
