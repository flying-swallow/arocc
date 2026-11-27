// #kind: run
// #exit: 0
// #opt: -w

#define NOINLINE __attribute__((noinline))

static NOINLINE int mixed_args(int a, double dead1, int dead2, double scale,
			       int *p, double dead3, int b, int dead4)
{
	return a + (int)scale + *p + b;
}

static NOINLINE int recursive_args(int depth, int a, int dead1, int b,
				   int c, int dead2, int d, int e, int f,
				   int g, int dead3)
{
	if (depth == 0) return a + b + c + d + e + f + g;
	return recursive_args(depth - 1, a + 1, dead1 + 1, b + 1,
			      c + 1, dead2 + 1, d + 1, e + 1, f + 1,
			      g + 1, dead3 + 1);
}

int main(void)
{
	volatile int value = 17;
	int pointed = 11;
	if (mixed_args(value, 1.5, 23, 3.0, &pointed, 2.5, 19, 29) != 50)
		return 1;
	if (recursive_args(2, 1, 101, 2, 3, 102, 4, 5, 6, 7, 103) != 42)
		return 2;
	return 0;
}
