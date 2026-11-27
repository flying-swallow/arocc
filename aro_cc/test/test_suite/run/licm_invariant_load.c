// #kind: run
// #exit: 45

static int f(int n, int k)
{
	int a[8];
	int b[8];
	for (int j = 0; j < 8; j++)
	{
		a[j] = j * k;
		b[j] = 0;
	}
	int s = 0;
	for (int i = 0; i < n; i++)
	{
		b[i & 7] += a[3];
		s += a[3];
	}
	return s + b[0];
}

static int g(int n)
{
	int a[8];
	for (int j = 0; j < 8; j++) a[j] = 0;
	int s = 0;
	for (int i = 0; i < n; i++)
	{
		a[i & 7] = i;
		s += a[3];
	}
	return s;
}

int main(void)
{
	int first = f(5, 2);
	int second = g(6);
	if (first != 36 || second != 9) return 1;
	return first + second;
}
