// #kind: run
// #exit: 0
// A block's declarations end with the block: a sibling block that redeclares a
// name must not capture later uses of the outer variable (chibicc preprocess.c
// `subst`), and a `for` declaration ends with the loop.
static int *find(int k)
{
	static int v[4] = { 10, 20, 30, 40 };
	return k >= 0 && k < 4 ? &v[k] : 0;
}
int main(void)
{
	int out = 0;
	for (int k = 0; k < 4; k++)
	{
		if (k == 9) { int *arg = find(0); out += *arg; continue; }
		int *arg = find(k);
		if (k == 8) { int *arg = find(3); out += *arg; continue; }
		if (arg) out += *arg;
	}
	if (out != 100) return 1;
	int i = 5;
	for (int i = 0; i < 3; i++) out++;
	if (i != 5) return 2;
	{
		int i = 7;
		if (i != 7) return 3;
	}
	return i == 5 ? 0 : 4;
}
