// #kind: run
// #exit: 0
static int sum_invariant(int n, int a, int b)
{
	int sum = 0;
	for (int i = 0; i < 9; i++)
	{
		// The product is independent of i and can be evaluated before the loop.
		sum += (n * 7 + 13) * 3;
		if (b) sum += a / b;
	}
	return sum;
}

int main(void)
{
	int without_division = 9 * ((5 * 7 + 13) * 3);
	int with_division = without_division + 9 * (21 / 3);
	return sum_invariant(5, 21, 0) == without_division &&
		sum_invariant(5, 21, 3) == with_division ? 0 : 1;
}
