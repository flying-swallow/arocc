// #kind: run
// #exit: 73
/* sizeof/_Alignof operands of non-constant arithmetic keep their value for
   codegen (Zig Result.shouldEval saves both operands). */
struct P { int a; double b; };
int main(int argc, char **argv)
{
	(void)argv;
	long n = argc + 9;                                   /* 10 */
	unsigned long a = sizeof(int) * n;                   /* 40 */
	unsigned long b = n * sizeof(struct P);              /* 160 */
	unsigned long c = (long)sizeof(short) * n + _Alignof(double); /* 28 */
	int buf[16];
	int *v = buf + (sizeof(int) * n) / 64; /* buf + 0 */
	for (long i = 0; i < n; i++) v[i] = (int)i;
	long s = 0;
	for (long i = 0; i < n; i++) s += v[i];              /* 45 */
	return (int)(a + b + c + s - 200);                   /* 73 */
}
