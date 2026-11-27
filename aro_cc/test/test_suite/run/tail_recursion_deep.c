// #kind: run
// #exit: 42
// #opt: -O2

static long long sum_down(long long n, long long total)
{
	if (n == 0) return total;
	return sum_down(n - 1, total + n);
}

static int gcd(int a, int b)
{
	if (b == 0) return a;
	return gcd(b, a % b);
}

int main(void)
{
	if (sum_down(100000000, 0) != 5000000050000000LL) return 1;
	if (gcd(200000000, 60000000) != 20000000) return 2;
	return 42;
}
