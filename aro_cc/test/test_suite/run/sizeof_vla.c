// #kind: run
// #exit: 42
/* sizeof a variable length array is a run-time size_t (C11 6.5.3.4p2). */
int g(int n) { int a[n][3]; return sizeof a; }
int h(int n) { return sizeof(char[n * 2]); }
int k(int n) { int a[n]; int b[sizeof a / sizeof a[0]]; return sizeof b; }
int main(void)
{
	int n = 5;
	int a[n];
	unsigned long s = sizeof a;
	if (s != 20) return 1;
	if (g(4) != 48) return 2;
	if (h(7) != 14) return 3;
	if (k(6) != 24) return 4;
	if (sizeof(a) / sizeof(a[0]) != 5) return 5;
	return 42;
}
