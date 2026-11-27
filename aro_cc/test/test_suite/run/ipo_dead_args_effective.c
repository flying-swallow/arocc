// #kind: run
// #exit: 0

#define NOINLINE __attribute__((noinline))

static volatile int effects;

static int side_effect(void)
{
	effects++;
	return 99;
}

static NOINLINE int effective_args(int a, double dead_fp1, int b, int dead_gp,
				   double live_fp, int c, double dead_fp2, int d)
{
	return a + b + (int)live_fp + c + d;
}

static NOINLINE int variadic_effective_args(int a, double dead_fp, int dead_gp,
					    ...)
{
	return a;
}

static NOINLINE int scalar_result(int value, int dead)
{
	return value * 3;
}

struct large_result {
	long first;
	long second;
	long third;
};

static NOINLINE struct large_result struct_result(long value, double dead_fp,
							  long dead_gp)
{
	struct large_result result = { value, value + 1, value + 2 };
	return result;
}

static double r(int n, int dead, double s, int *p, double dead2)
{
	if (!n) return s + *p;
	return r(n - 1, 0, s * 2, p, 0.0);
}

int main(void)
{
	if (effective_args(3, 1.5, 2, side_effect(), 5.0,
			   7, (double)side_effect(), 11) != 28) return 1;
	if (effects != 2) return 2;

	if (variadic_effective_args(13, 1.5, side_effect()) != 13) return 3;
	if (variadic_effective_args(17, 2.5, side_effect(), 23, 4.5,
				    side_effect(), 31) != 17) return 4;
	if (effects != 5) return 5;

	if (scalar_result(7, side_effect()) != 21) return 6;
	scalar_result(9, side_effect());
	if (effects != 7) return 7;

	struct large_result first = struct_result(20, 3.5, side_effect());
	if (first.first != 20 || first.second != 21 || first.third != 22) return 8;
	struct large_result second = struct_result(40, 5.5, side_effect());
	if (second.first != 40 || second.second != 41 || second.third != 42) return 9;
	if (effects != 9) return 10;

	int recursive_value = 5;
	if (r(3, 100, 1.5, &recursive_value, 4.0) != 17.0) return 11;
	return 0;
}
