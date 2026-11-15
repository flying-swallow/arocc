// #kind: run
// #exit: 36
int main(void)
{
	int a = 1;
	int b = 2;
	for (int i = 0; i < 5; i++)
	{
		int t = ((i & 1) && (a || b)) ? a : b;
		a = b;
		b = t + a;
	}
	return b;
}
