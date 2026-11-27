// #kind: run
// #exit: 0

static int f(int c, int n)
{
	int x = 0;
	if (c) goto B;
A:
	x += 1;
	if (x > n) return x;
B:
	x += 2;
	if (x < 100) goto A;
	return x;
}

int main(void)
{
	if (f(0, 10) != 13) return 1;
	if (f(1, 10) != 12) return 2;
	return 0;
}
